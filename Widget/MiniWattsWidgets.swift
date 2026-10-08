import SwiftUI
import WidgetKit

@main
struct MiniWattsWidgets: WidgetBundle {
    var body: some Widget {
        BatteryWidget()
        ChargeLiveActivity()
    }
}
