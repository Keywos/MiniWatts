import Foundation
import WidgetKit

/// Keeps the widget extension supplied from the app side.
///
/// The extension reads the sensors itself at every refresh, so this is not what makes
/// the widget current. It does the two things the extension cannot:
/// - leaves the last finished charge in the App Group container — session history
///   lives in the app's own container, which the extension cannot see
/// - asks WidgetKit to refresh when something the widget shows has actually changed
///   (plugging in, unplugging, a charge finishing) instead of waiting out a refresh
///   budget of roughly one every 15–60 minutes.
///
/// Reload requests made while the app is in the foreground do not count against that
/// budget, which is why they are made here, from the app's own tick.
final class WidgetPublisher {
    private var lastWrite: Date = .distantPast
    private var lastConnected: Bool?
    private var lastSessionID: UUID?

    /// Called once per tick. Writes at most once a minute, and immediately on a plug
    /// event or a newly finished session.
    func publish(_ reading: ChargeReading, lastSession: ChargeSession?) {
        let plugChanged = lastConnected.map { $0 != reading.externalConnected } ?? true
        let sessionChanged = lastSession?.id != lastSessionID
        let due = reading.date.timeIntervalSince(lastWrite) >= 60
        guard plugChanged || sessionChanged || due else { return }
        write(reading, lastSession: lastSession)
        if plugChanged || sessionChanged {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Called as the app leaves the foreground, so the fallback the extension reads is
    /// as fresh as it can be.
    func flush(_ reading: ChargeReading, lastSession: ChargeSession?) {
        write(reading, lastSession: lastSession)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func write(_ reading: ChargeReading, lastSession: ChargeSession?) {
        lastWrite = reading.date
        lastConnected = reading.externalConnected
        lastSessionID = lastSession?.id
        // A false return is the normal case on a sideloaded copy whose signing tool
        // did not carry the App Group over; the extension then reads sensors only.
        WidgetSnapshot(reading: reading,
                       lastSession: lastSession.map(WidgetSnapshot.Session.init))
            .save()
    }
}

nonisolated extension WidgetSnapshot.Session {
    init(_ session: ChargeSession) {
        self.init(start: session.start,
                  end: session.end ?? session.start.addingTimeInterval(session.duration),
                  startPercent: session.startPercent,
                  endPercent: session.endPercent,
                  storedWattHours: session.totals.batteryWattHours,
                  deliveredWattHours: session.totals.measuredInputWattHours,
                  efficiencyPercent: session.totals.efficiencyPercent,
                  peakWatts: max(session.peakInputWatts, session.peakBatteryWatts),
                  isWireless: session.isWireless)
    }
}
