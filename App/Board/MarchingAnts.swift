import SwiftUI

/// The "this exact thing will take the drop" border. A crawling dash reads as a live target
/// in a way a static tint doesn't — which is the whole complaint about dropping an image on
/// a board: nothing said which card was about to receive it.
private struct MarchingAntsModifier: ViewModifier {
    let active: Bool
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        MeatPadGlass.violet,
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4], dashPhase: phase)
                    )
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) {
                            phase = -10   // one full dash period, so the loop has no seam
                        }
                    }
                    .onDisappear { phase = 0 }
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func marchingAnts(_ active: Bool, cornerRadius: CGFloat) -> some View {
        modifier(MarchingAntsModifier(active: active, cornerRadius: cornerRadius))
    }
}
