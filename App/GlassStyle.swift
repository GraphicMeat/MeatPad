import SwiftUI

/// A small, shared visual language for MeatPad's translucent surfaces. Keeping the
/// effects here makes the UI feel cohesive and avoids stacking expensive materials.
enum MeatPadGlass {
    static let cornerRadius: CGFloat = 16
    static let tint = Color(red: 0.96, green: 0.32, blue: 0.28)
    static let violet = Color(red: 0.48, green: 0.38, blue: 0.96)
    static let cyan = Color(red: 0.20, green: 0.67, blue: 0.96)
}

struct AmbientGlassBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            GeometryReader { proxy in
                Circle()
                    .fill(MeatPadGlass.violet.opacity(0.14))
                    .frame(width: proxy.size.width * 0.9)
                    .blur(radius: 70)
                    .offset(x: proxy.size.width * 0.52, y: -proxy.size.height * 0.38)

                Circle()
                    .fill(MeatPadGlass.tint.opacity(0.11))
                    .frame(width: proxy.size.width * 0.75)
                    .blur(radius: 80)
                    .offset(x: -proxy.size.width * 0.32, y: proxy.size.height * 0.62)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct GlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    let shadow: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.42), .white.opacity(0.10), .white.opacity(0.20)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
            }
            .shadow(color: .black.opacity(shadow ? 0.20 : 0), radius: 24, y: 12)
            .shadow(color: MeatPadGlass.violet.opacity(shadow ? 0.08 : 0), radius: 30, y: 8)
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = MeatPadGlass.cornerRadius, shadow: Bool = true) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius, shadow: shadow))
    }
}

struct GlassIconButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? .white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                Capsule(style: .continuous)
                    .fill(selected ? AnyShapeStyle(MeatPadGlass.violet.gradient) : AnyShapeStyle(.thinMaterial))
                    .opacity(configuration.isPressed ? 0.72 : 1)
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(.white.opacity(selected ? 0.26 : 0.18), lineWidth: 0.75)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GlassSearchField: View {
    let prompt: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            if let focused {
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .focused(focused)
            } else {
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.75)
        }
    }
}
