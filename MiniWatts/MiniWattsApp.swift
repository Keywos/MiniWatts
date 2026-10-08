import AppIntents
import SwiftUI

@main
struct MiniWattsApp: App {
    @State private var monitor: PowerMonitor

    init() {
        let monitor = PowerMonitor()
        _monitor = State(initialValue: monitor)
        // The Shortcuts action runs in this process — launched in the background, with
        // no scene, when the app is not already running — and has to read through this
        // monitor's sensors rather than open its own: a process gets one working HID
        // client, and a second one reads NaN. Registered here because `init` is the
        // one place that runs on every launch, scene or no scene.
        AppDependencyManager.shared.add(dependency: monitor)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(monitor)
        }
    }
}
