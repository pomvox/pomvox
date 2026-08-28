import Darwin
import Foundation

/// Pidfile mutual exclusion — one event tap / mic at a time across the native
/// and Python engines. Mirror of `src/pomvox/pidfile.py`; the file format is the
/// cross-engine contract: line 1 = pid, line 2 = owner name ("native" |
/// "python"), line 3 = the owner's executable path. The native engine acquires
/// before arming and refuses if a live Python engine already holds it.
///
/// Line 3 exists because **a pid is not an identity**. It is a small integer the
/// kernel hands back out, and Pomvox is a login item — it starts early and gets
/// a *low* pid, exactly the range other early-boot daemons are assigned after a
/// reboot. A liveness test alone (`kill(pid, 0)`) therefore reports a stale
/// pidfile as a live holder essentially forever: seen in the field 2026-08-27,
/// where `985 / native` survived a reboot, pid 985 came back as `usernoted`, and
/// the engine refused to arm on every launch with no way for the user to
/// recover but to delete the file by hand. Matching the recorded path against
/// what the pid is *actually* running rejects that case.
///
/// (`flock(2)` would let the kernel own the lifetime and is the tidier
/// primitive, but a lock taken by a running older build would be invisible to a
/// new one — the upgrade window would allow two live engines, two event taps and
/// two mic clients. Identity keeps a real holder blocking across versions.)
struct Pidfile {
    struct Owner: Equatable {
        let pid: Int32
        let name: String
        /// The executable the owner was running. nil on a legacy 2-line file.
        let execPath: String?

        init(pid: Int32, name: String, execPath: String? = nil) {
            self.pid = pid
            self.name = name
            self.execPath = execPath
        }
    }

    /// What the OS says about a pid right now. Separated from the decision so
    /// the decision stays pure and unit-tested (the `HudProbe` pattern).
    enum Identity: Equatable {
        case dead                    // no such process
        case running(path: String)   // alive, and this is its executable
        case unverifiable            // alive, but owned by another user
    }

    let url: URL

    static let defaultURL = URL(fileURLWithPath:
        NSString(string: "~/.pomvox/engine.pid").expandingTildeInPath)

    init(url: URL = Pidfile.defaultURL) { self.url = url }

    // MARK: - OS probes (the only impure part)

    static func pidAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM  // exists, owned by another user
    }

    /// `proc_pidpath` for a live pid. Fails (0) for a dead pid and for one we
    /// aren't allowed to inspect — `kill` separates those two.
    static func identity(of pid: Int32) -> Identity {
        guard pidAlive(pid) else { return .dead }
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is a C macro in libproc.h,
        // so it doesn't survive the Swift import — spell the value out.
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let written = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard written > 0 else { return .unverifiable }
        return .running(path: String(cString: buf))
    }

    /// What we record for ourselves. Deliberately read through `identity(of:)`
    /// rather than `Bundle.main`: the value written must be byte-identical to
    /// what a *later* `proc_pidpath` on this pid would return, or every holder
    /// would look recycled to itself.
    static func currentExecPath() -> String {
        let mine = ProcessInfo.processInfo.processIdentifier
        if case .running(let path) = identity(of: mine) { return path }
        return Bundle.main.executablePath ?? "Pomvox"
    }

    // MARK: - file IO

    func read() -> Owner? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first,
              let pid = Int32(first.trimmingCharacters(in: .whitespaces)) else { return nil }
        let name = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespaces) : ""
        let path = lines.count > 2 ? String(lines[2]).trimmingCharacters(in: .whitespaces) : ""
        return Owner(pid: pid, name: name, execPath: path.isEmpty ? nil : path)
    }

    /// The live owner, or nil (no file, dead pid, or a pid that has since been
    /// recycled to an unrelated process).
    func currentHolder() -> Owner? {
        guard let owner = read() else { return nil }
        return pidfileOwnerIsLive(owner, identity: Self.identity(of: owner.pid)) ? owner : nil
    }

    /// Claim for `name`. Returns nil on success, or the live foreign holder that
    /// blocked the claim (the caller then refuses to arm). A live *other* pid
    /// blocks; our own pid, a dead pid, or a recycled one is overwritten. Atomic
    /// write.
    @discardableResult
    func acquire(_ name: String,
                 pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                 execPath: String = Pidfile.currentExecPath()) -> Owner? {
        if let holder = currentHolder(), holder.pid != pid { return holder }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(pid)\n\(name)\n\(execPath)\n".write(to: url, atomically: true, encoding: .utf8)
        return nil
    }

    /// Remove the pidfile if this pid still owns it (no-op otherwise).
    func release(pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        guard let owner = read(), owner.pid == pid else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - the decision (pure)

/// Is the process behind `owner.pid` still the one that wrote the pidfile?
///
/// A recorded exec path is matched exactly. A legacy 2-line file has nothing to
/// match, so it falls back to a shape test: a path that could plausibly be the
/// engine named in the file is trusted, anything else is treated as a recycled
/// pid. Being wrong in the trusting direction only costs a spurious "blocked";
/// being wrong the other way would let two engines share the mic.
func pidfileOwnerIsLive(_ owner: Pidfile.Owner, identity: Pidfile.Identity) -> Bool {
    switch identity {
    case .dead:
        return false
    case .unverifiable:
        // Another user's process: we can't read its path and mustn't steal a
        // lock we can't disprove.
        return true
    case .running(let actualPath):
        if let recorded = owner.execPath { return recorded == actualPath }
        return legacyPathCouldBeEngine(actualPath, name: owner.name)
    }
}

/// Shape test for pidfiles written before the exec-path line existed.
func legacyPathCouldBeEngine(_ path: String, name: String) -> Bool {
    let base = (path as NSString).lastPathComponent.lowercased()
    switch name {
    case "native":
        return base == "pomvox"
    case "python":
        // Console script, `uv run`, or a bare interpreter (python, python3.12).
        return base == "pomvox" || base == "uv" || base.hasPrefix("python")
    default:
        return false
    }
}
