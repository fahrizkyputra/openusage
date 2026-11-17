import Foundation

/// Team builds: telemetry is off. This sink takes every event and does nothing with it, so there is no
/// PostHog setup, no daily ping, no crash reports, and no network to the analytics host.
@MainActor
final class TeamTelemetrySink: TelemetrySink {
    /// Always zero: events are dropped, never retained.
    private(set) var capturedCount = 0

    func capture(_ event: String, _ properties: [String: Any]) {}
    func flush() {}
}
