import SwiftUI

// The wording of a reading — the source captions, the status title, the symbol —
// lives in `MiniWatts/Shared/ReadingWording.swift`, which both targets compile, so
// the widget and the app cannot describe the same reading differently. What is left
// here is the drawing.

/// Level as a thin bar, the widget-sized cousin of the app's charge bar.
struct LevelBar: View {
    let percent: Int?
    let tint: Color
    let track: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(tint)
                    .frame(width: max(height, geometry.size.width * CGFloat(min(max(Double(percent ?? 0) / 100, 0), 1))))
            }
        }
        .frame(height: height)
    }
}

/// The app's 280° dial, reduced to a single level arc.
struct LevelRing: View {
    let percent: Int?
    let tint: Color
    let track: Color
    var lineWidth: CGFloat = 9

    private let sweep: CGFloat = 280.0 / 360.0

    var body: some View {
        let fraction = CGFloat(min(max(Double(percent ?? 0) / 100, 0), 1))
        ZStack {
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: sweep * fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
        .rotationEffect(.degrees(130))
        .padding(lineWidth / 2)
    }
}
