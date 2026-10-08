import Foundation

/// Reads the sensors from inside the widget extension, at refresh time.
///
/// This is the widget's primary source. The App Group container the app writes to
/// may not exist on a re-signed sideloaded copy, and even where it does, the app is
/// rarely running — so the extension does its own read, with the same IOKit and HID
/// code the app uses.
nonisolated enum ReadingProbe {
    // A process gets exactly one working HID event client: a second one reads NaN for
    // every service. The extension process can outlive a single refresh, so the client
    // is created once and kept, and every read goes through the lock.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var created = false
    nonisolated(unsafe) private static var sensors: HIDSensors?
    nonisolated(unsafe) private static var battery: IOKitBattery?

    /// Nil when nothing at all answered — no powerd, no registry, no sensors.
    static func read() -> ChargeReading? {
        lock.lock()
        defer { lock.unlock() }

        if created {
            // Charger-side sensors only exist while something is plugged in.
            sensors?.rescan()
        } else {
            sensors = HIDSensors()
            battery = IOKitBattery()
            created = true
        }

        let registry = battery?.readRegistryProperties() ?? [:]
        let sources = battery?.readPowerSources() ?? []
        let internalBattery = sources.first { ($0["Type"] as? String) == "InternalBattery" } ?? sources.first
        let readings = sensors?.read() ?? []
        guard internalBattery != nil || !registry.isEmpty || !readings.isEmpty else { return nil }

        let snapshot = PowerSnapshot(date: .now,
                                     registry: registry,
                                     powerSource: internalBattery,
                                     adapterDetails: battery?.readAdapterDetails(),
                                     sensors: readings)
        return ChargeReading(snapshot)
    }
}
