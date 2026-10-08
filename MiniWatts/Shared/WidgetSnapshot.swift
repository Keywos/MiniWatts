import Foundation

/// What the app leaves behind for the widget extension, in the App Group container.
///
/// This is the fallback, not the main source. The extension reads the sensors
/// itself at every refresh; this file only supplies what a single refresh cannot
/// know — the last finished charge — and a last reading for when the extension's
/// own read comes back empty.
///
/// The container may not exist at all. An App Group entitlement survives a signed
/// build from Xcode, but re-signing tools vary in whether they carry it over, so on
/// a sideloaded copy `containerURL` can be nil. Every caller treats that as normal.
nonisolated struct WidgetSnapshot: Codable, Hashable {
    /// A finished charge, reduced to what fits on a widget.
    struct Session: Codable, Hashable {
        var start: Date
        var end: Date
        var startPercent: Int
        var endPercent: Int
        var storedWattHours: Double
        /// Nil when the input side was never measurable — a wireless charge.
        var deliveredWattHours: Double?
        var efficiencyPercent: Double?
        var peakWatts: Double
        var isWireless: Bool

        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    var reading: ChargeReading
    var lastSession: Session?

    static let groupIdentifier = "group.org.zhaohe.MiniWatts"
    private static let filename = "widget-snapshot.json"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)?
            .appendingPathComponent(filename)
    }

    /// Whether the App Group container is reachable from this process at all.
    static var isContainerAvailable: Bool { fileURL != nil }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Returns false when there is no container to write into.
    @discardableResult
    func save() -> Bool {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
