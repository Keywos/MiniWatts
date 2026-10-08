import SwiftUI

struct SettingsView: View {
    @Environment(PowerMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var monitor = monitor
        NavigationStack {
            ZStack {
                Backdrop(glow: .mwAccent, glowIntensity: 0.6)
                ScrollView {
                    VStack(spacing: 14) {
                        pipPanel
                        recordingPanel(keepAwake: $monitor.keepScreenAwakeWhileCharging)
                        glancesPanel(liveActivity: $monitor.showsLiveActivityWhileCharging,
                                     metric: $monitor.liveActivityMetric)
                        capacityPanel(capacity: $monitor.configuredBatteryWattHours)
                        devicePanel
                        aboutPanel
                        rawDataLink
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    // Pinned to the container's width so nothing inside can widen the
                    // scroll content. A paragraph inside an HStack reports an enormous
                    // ideal width — the text unwrapped onto one line — and
                    // `.frame(maxWidth: .infinity)` only expands, it does not clamp, so
                    // that width propagates up and the page starts scrolling sideways.
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.tint(.mwAccent)
                }
            }
        }
    }

    private func recordingPanel(keepAwake: Binding<Bool>) -> some View {
        Panel("Recording", systemImage: "record.circle") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: keepAwake) {
                    Text("Keep the screen on while charging")
                        .font(.system(size: 14, weight: .medium))
                }
                .tint(.mwAccent)
                Text("Sensors can only be read while MiniWatts is on screen, so a charge is only recorded for as long as the phone stays awake. With this on, the screen is held on — but only while a charger is connected, never on battery.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A charge session survives the app being backgrounded: it ends when you unplug, not when you switch away. Any stretch the app missed is left out of the totals rather than estimated, and the session says how much of itself was actually measured.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func glancesPanel(liveActivity: Binding<Bool>,
                              metric: Binding<LiveActivityMetric>) -> some View {
        Panel("Lock Screen and widgets", systemImage: "rectangle.on.rectangle") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: liveActivity) {
                    Text("Live Activity while charging")
                        .font(.system(size: 14, weight: .medium))
                }
                .tint(.mwAccent)

                HStack {
                    Text("Primary readout")
                        .font(.subheadline)
                    Spacer()
                    Picker("Primary readout", selection: metric) {
                        Text("Charging power").tag(LiveActivityMetric.chargingPower)
                        Text("SoC temperature").tag(LiveActivityMetric.socTemperature)
                        Text("Battery temperature").tag(LiveActivityMetric.batteryTemperature)
                        Text("Hottest component").tag(LiveActivityMetric.hottestTemperature)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                Text("The compact Dynamic Island shows this reading. Press and hold it to see power, SoC, battery and hottest-component temperatures together.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The activity starts while a charger is connected and MiniWatts is in front, refreshes while MiniWatts runs, and marks the reading paused once the app is suspended. Unplug with MiniWatts running and it ends two minutes later; unplug while it is suspended and it stays until MiniWatts runs again. Tap End on the activity to close it at any time.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Widgets read the sensors themselves whenever iOS refreshes them — usually every 15 to 60 minutes — and straight away when you plug in or unplug with MiniWatts open. Each one says when its numbers were taken.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The one surface that can show a number that moves while the app is off
    /// screen. Manual on purpose: it is a window over everything else and it keeps
    /// the app running.
    private var pipPanel: some View {
        @Bindable var pipManager = PiPManager.shared
        return Panel("Picture in Picture", systemImage: "pip") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PiP HUD Overlay")
                            .font(.system(size: 14, weight: .medium))
                        Text("Show live current, voltage, power, and temperatures (CPU, Battery, Charger IC) in a floating Picture-in-Picture window.")
                            .font(.caption)
                            .foregroundStyle(Color.mwMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(pipManager.isActive ? "Stop" : "Start") {
                        pipManager.togglePiP()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.mwAccent)
                    .controlSize(.small)
                }

                Text("While the window is open MiniWatts keeps running, so it also records the charge with the screen locked — and it draws more power than being suspended. Close the window when you are done with it. No sound is ever played; the window uses the same system feature as a video playing in the corner, which is why the app declares audio playback at all.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func capacityPanel(capacity: Binding<Double>) -> some View {
        Panel("Battery energy", systemImage: "battery.100.bolt") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(String(format: "%.1f Wh", capacity.wrappedValue))
                        .mwReadout(size: 26)
                        .foregroundStyle(Color.mwAccent)
                    Spacer()
                    Stepper("", value: capacity, in: 5...40, step: 0.1)
                        .labelsHidden()
                }
                Text("Used only for the %-rate estimate, which is the sole way to see discharge power: no discharge-current sensor is exposed to a sandboxed app. Look up your model's rating — an iPhone 17 Pro Max is about 19.7 Wh — and enter it here.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let designCapacity = monitor.snapshot.designCapacity, designCapacity > 0 {
                    EmptyNote(text: "IOKit reported a design capacity of \(designCapacity) mAh on this system, so that value is being used instead.",
                              systemImage: "checkmark.circle")
                }
            }
        }
    }

    private var devicePanel: some View {
        Panel("Device", systemImage: "iphone") {
            VStack(spacing: 0) {
                DetailRow(label: "Model identifier", value: monitor.deviceModelIdentifier)
                DetailRow(label: "System", value: "iOS \(UIDevice.current.systemVersion)")
                DetailRow(label: "HID sensors",
                          value: monitor.sensorsAvailable
                              ? String(localized: "available") : String(localized: "unavailable"))
                DetailRow(label: "Cycle count", value: monitor.snapshot.cycleCount.map(String.init))
                DetailRow(label: "Battery health",
                          value: monitor.snapshot.healthPercent.map { String(format: "%.0f%%", $0) })
            }
        }
    }

    /// In the distributed ipa too, not just Debug builds. It used to be `#if DEBUG`
    /// on the grounds that a raw dump is a development tool — but the probes it runs
    /// answer questions that can only be answered on hardware this project does not
    /// have, and every one of those answers has arrived as a dump pasted by someone
    /// running the release build. Kept at the bottom of Settings, behind a link that
    /// says what it is, so nobody meets it by accident.
    private var rawDataLink: some View {
        NavigationLink {
            DebugView()
        } label: {
            Panel {
                HStack(spacing: 10) {
                    Image(systemName: "ladybug")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.mwMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Raw data")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("Every value the probes returned, unedited.")
                            .font(.caption)
                            .foregroundStyle(Color.mwMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mwMuted)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Where the source lives. Kept as a constant rather than built inline: a typo in
    /// a string literal would only show up as a force-unwrap crash on this screen.
    private static let repository = URL(string: "https://github.com/Keywos/MiniWatts")!

    private var aboutPanel: some View {
        Panel("About", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.mwAccent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Free and open source")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Apache 2.0 licence. The whole app, widget included, is on GitHub.")
                            .font(.caption)
                            .foregroundStyle(Color.mwMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Link(destination: Self.repository) {
                    HStack(spacing: 8) {
                        Text(verbatim: "github.com/Keywos/MiniWatts")
                            .mwMono(size: 12, weight: .medium)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color.mwAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.mwAccent.opacity(0.1))
                    )
                }
                .padding(.bottom, 4)
                Text("MiniWatts reads the phone's own power management sensors through private frameworks — IOKit, IOHIDEventSystemClient and BatteryCenter. Nothing leaves the device and nothing is written outside the app's own container.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Those APIs are private, so this build is for sideloading only: it cannot pass App Store review, and any iOS update may change or remove what it reads.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Sensor names, scales and even which sensors exist differ from model to model, and nothing about them is documented. This build was written and checked on an iPhone Air (iPhone18,4). On another model a reading can be missing, or belong to something other than its name suggests. Values that are impossible are hidden rather than shown, but a wrong value that happens to look reasonable cannot be caught that way — so treat anything surprising as suspect, and please report it with your model identifier.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
