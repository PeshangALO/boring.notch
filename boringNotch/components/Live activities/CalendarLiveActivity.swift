//
//  CalendarLiveActivity.swift
//  boringNotch
//
//  Right-side ring of the closed-notch calendar live activity: a countdown
//  ring around a calendar glyph. `progress` is 1 (full) → 0 (empty).
//

import SwiftUI

struct CalendarLiveActivityRing: View {
    let progress: Double
    var size: CGFloat

    // ponytail: 2.5pt stroke, inset so it draws inside `size` instead of straddling the edge.
    private let lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.red.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    Color.red,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: progress)
        }
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
    }
}
