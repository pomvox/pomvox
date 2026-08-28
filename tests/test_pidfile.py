import os

from pomvox import pidfile
from pomvox.pidfile import Identity, Liveness, Owner

DEAD = 999_999  # a pid that won't exist (macOS default pid_max is ~99999)


def _file(tmp_path):
    return tmp_path / "engine.pid"


def _me():
    return os.getpid()


def _my_path():
    return pidfile.current_exec_path()


# --- acquire / release ------------------------------------------------------


def test_acquire_on_empty_writes_and_returns_none(tmp_path):
    p = _file(tmp_path)
    assert pidfile.acquire("native", pid=_me(), path=p) is None
    assert pidfile.read(p) == Owner(_me(), "native", _my_path())


def test_acquire_blocked_by_live_other_holder(tmp_path):
    p = _file(tmp_path)
    # Our own (alive) pid claims it as the python engine.
    assert pidfile.acquire("python", pid=_me(), path=p) is None
    # A different pid trying to claim it is refused, told who holds it.
    blocker = pidfile.acquire("native", pid=DEAD, path=p)
    assert blocker == Owner(_me(), "python", _my_path())
    # The file is untouched — the live holder keeps it.
    assert pidfile.read(p) == Owner(_me(), "python", _my_path())


def test_acquire_overwrites_stale_dead_pid(tmp_path):
    p = _file(tmp_path)
    # A dead pid wrote the file (process crashed without releasing).
    pidfile.acquire("python", pid=DEAD, path=p)
    assert pidfile.current_holder(p) is None  # dead → no live holder
    # The new engine claims it cleanly.
    assert pidfile.acquire("native", pid=_me(), path=p) is None
    assert pidfile.read(p) == Owner(_me(), "native", _my_path())


def test_release_only_removes_when_we_own_it(tmp_path):
    p = _file(tmp_path)
    pidfile.acquire("python", pid=_me(), path=p)
    pidfile.release(pid=_me(), path=p)
    assert pidfile.read(p) is None

    # A file owned by another pid is left alone.
    pidfile.acquire("native", pid=DEAD, path=p)
    pidfile.release(pid=_me(), path=p)
    assert pidfile.read(p).pid == DEAD


# --- parsing ----------------------------------------------------------------


def test_read_missing_and_malformed(tmp_path):
    p = _file(tmp_path)
    assert pidfile.read(p) is None
    p.write_text("not-a-pid\nnative\n")
    assert pidfile.read(p) is None
    assert pidfile.current_holder(p) is None


def test_read_legacy_two_line_file_has_no_exec_path(tmp_path):
    p = _file(tmp_path)
    p.write_text("4242\nnative\n")
    assert pidfile.read(p) == Owner(4242, "native", None)


def test_read_three_line_file_carries_exec_path(tmp_path):
    p = _file(tmp_path)
    p.write_text("4242\nnative\n/Applications/Pomvox.app/Contents/MacOS/Pomvox\n")
    assert pidfile.read(p) == Owner(
        4242, "native", "/Applications/Pomvox.app/Contents/MacOS/Pomvox"
    )


# --- the decision (pure) ----------------------------------------------------


def test_dead_pid_is_never_live():
    owner = Owner(42, "native", "/x/Pomvox")
    assert not pidfile.owner_is_live(owner, Identity(Liveness.DEAD))


def test_matching_exec_path_is_live():
    owner = Owner(42, "native", "/x/Pomvox")
    assert pidfile.owner_is_live(owner, Identity(Liveness.RUNNING, "/x/Pomvox"))


def test_recycled_pid_running_another_process_is_not_live():
    """The 2026-08-27 field failure: a reboot handed the recorded pid to an
    unrelated daemon and the stale lock read as live forever."""
    owner = Owner(985, "native", "/Applications/Pomvox.app/Contents/MacOS/Pomvox")
    assert not pidfile.owner_is_live(
        owner, Identity(Liveness.RUNNING, "/usr/sbin/usernoted")
    )


def test_unverifiable_pid_is_treated_as_live():
    # Another user's process: we cannot disprove it, so we must not steal it.
    owner = Owner(42, "native", "/x/Pomvox")
    assert pidfile.owner_is_live(owner, Identity(Liveness.UNVERIFIABLE))


# --- legacy files (no exec-path line to match) ------------------------------


def test_legacy_file_trusts_a_plausible_engine_path():
    owner = Owner(42, "native", None)
    assert pidfile.owner_is_live(
        owner,
        Identity(Liveness.RUNNING, "/Applications/Pomvox.app/Contents/MacOS/Pomvox"),
    )


def test_legacy_file_rejects_a_recycled_pid():
    owner = Owner(985, "native", None)
    assert not pidfile.owner_is_live(
        owner, Identity(Liveness.RUNNING, "/usr/sbin/usernoted")
    )


def test_legacy_python_shapes():
    ok = pidfile.legacy_path_could_be_engine
    assert ok("/opt/homebrew/bin/python3.12", "python")
    assert ok("/Users/x/.venv/bin/pomvox", "python")
    assert ok("/opt/homebrew/bin/uv", "python")
    assert not ok("/usr/sbin/usernoted", "python")
    assert not ok("/usr/sbin/usernoted", "native")
    assert not ok("/x/Pomvox", "mystery-engine")


# --- end to end, against a genuinely live pid -------------------------------


def test_acquire_breaks_a_lock_whose_live_pid_runs_something_else(tmp_path):
    """A file naming our own live pid but a different executable is a recycled
    pid by definition — acquire must break it rather than block forever."""
    p = _file(tmp_path)
    p.write_text(f"{_me()}\nnative\n/usr/sbin/usernoted\n")
    assert pidfile.current_holder(p) is None
    assert pidfile.acquire("native", pid=DEAD, path=p) is None
    assert pidfile.read(p).pid == DEAD


def test_acquire_still_blocks_on_a_genuine_live_holder(tmp_path):
    """The same pid running the same executable is a real holder — still blocks."""
    p = _file(tmp_path)
    p.write_text(f"{_me()}\npython\n{_my_path()}\n")
    assert pidfile.current_holder(p).name == "python"
    assert pidfile.acquire("native", pid=DEAD, path=p).name == "python"


def test_identity_of_our_own_pid_is_running():
    ident = pidfile.identity(_me())
    assert ident.liveness is Liveness.RUNNING
    assert ident.exec_path == _my_path()
    assert pidfile.identity(DEAD).liveness is Liveness.DEAD
