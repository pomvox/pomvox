/// Reports a recurring condition once until it clears (#221).
///
/// arm() meets `input_monitoring_denied` on every attempt until the user grants
/// Input Monitoring, so emitting it each time let a few stuck installs read as
/// a telemetry error spike. The engine asks `shouldReport()` before emitting
/// and calls `clear()` when the tap installs, so a later revoke is reported
/// again. One engine per process makes this once per launch.
struct ReportLatch: Equatable {
    private(set) var reported = false

    /// True the first time after construction or `clear()`; false after that.
    mutating func shouldReport() -> Bool {
        defer { reported = true }
        return !reported
    }

    mutating func clear() { reported = false }
}
