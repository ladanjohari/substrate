import AppKit
import SwiftUI

/// The dot vocabulary, unchanged from Session Indicator.
///
///   idle     dim, still
///   working  ink, breathing (an agent is on it)
///   needs    amber, still (a person is needed)
///   error    red ring, told apart by shape as well as hue
///   done     green
///
/// Motion means state. Colour means exception.
enum Dot: String {
    case hollow, idle, working, needs, error, done

    init(_ raw: String) { self = Dot(rawValue: raw) ?? .idle }

    var color: Color {
        switch self {
        case .hollow, .idle: return .primary.opacity(0.35)
        case .working:       return .primary
        case .needs:         return Color(red: 0.85, green: 0.65, blue: 0.15)
        case .error:         return Color(red: 0.85, green: 0.30, blue: 0.25)
        case .done:          return Color(red: 0.20, green: 0.65, blue: 0.35)
        }
    }
}

/// A still capture of a breathing dot lands wherever the animation happened to
/// be, which is usually most of the way faded out, and the image then says the
/// dot is broken rather than alive. The render modes turn the breath off.
enum Motion {
    nonisolated(unsafe) static var still = false
}

struct DotView: View {
    let dot: Dot
    @State private var breathing = false

    private var reduceMotion: Bool {
        Motion.still || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    private var shouldBreathe: Bool { dot == .working && !reduceMotion }

    var body: some View {
        shape
            .frame(width: 7, height: 7)
            // The breath changes size as well as brightness, which reads as
            // something alive rather than something blinking.
            .scaleEffect(breathing ? 0.35 : 1)
            .opacity(breathing ? 0.15 : 1)
            .animation(shouldBreathe
                       ? .easeInOut(duration: 0.95).repeatForever(autoreverses: true)
                       : .default, value: breathing)
            .onAppear { breathing = shouldBreathe }
            .onChange(of: dot) { _, _ in breathing = shouldBreathe }
    }

    @ViewBuilder private var shape: some View {
        switch dot {
        case .hollow: Circle().strokeBorder(Dot.hollow.color, lineWidth: 1)
        case .error:  Circle().strokeBorder(Dot.error.color, lineWidth: 1.5)
        default:      Circle().fill(dot.color)
        }
    }
}

/// The menu bar item: one dot per task that matters, and a count for the rest.
struct PillView: View {
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(store.panel.pill.dots.enumerated()), id: \.offset) { _, raw in
                DotView(dot: Dot(raw))
            }
            if store.panel.pill.overflow > 0 {
                Text("+\(store.panel.pill.overflow)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.primary.opacity(0.8))
                    .padding(.leading, 1)
            }
            if store.offline {
                // Say the store is unreachable rather than showing stale dots
                // as if they were current.
                Image(systemName: "bolt.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.5))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(.primary.opacity(0.08)))
        .animation(.easeOut(duration: 0.35), value: store.panel.pill)
        .frame(height: 22)
    }
}
