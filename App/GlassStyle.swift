import SwiftUI
import AppKit
import MeatPadKit

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

extension View {
    /// SwiftUI draws a blue focus ring on plain/borderless controls even when the user never
    /// navigates by keyboard. Rings appear only for someone actually running assistive tech.
    ///
    /// Deliberately NOT gated on `NSApplication.isFullKeyboardAccessEnabled`: that setting
    /// (System Settings ▸ Keyboard ▸ Keyboard navigation) is switched on for plenty of people
    /// who never navigate by keyboard, and it made a ring stick to whatever took focus after
    /// collapsing the sidebar. Focusability is untouched either way — Tab still reaches every
    /// control, the effect just isn't drawn.
    // ponytail: read per scene build, not observed — turning VoiceOver on mid-run needs new
    // windows to take effect.
    /// A text field with no AppKit bezel. A bezeled field (`.roundedBorder`, or the default
    /// style) is an NSTextField, and AppKit draws its own focus ring on first responder —
    /// `focusEffectDisabled` governs SwiftUI's focus effects only and never reaches it. Plain
    /// field inside our own container is the app's answer everywhere, same as GlassSearchField.
    func ringlessField(cornerRadius: CGFloat = 7) -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    }
            }
    }

    /// Shift+Return and Option+Return add a line break instead of submitting — the chord
    /// every multi-line field on macOS answers to, which SwiftUI's `TextField` drops.
    /// The break is put in by AppKit's field editor rather than by rewriting the binding:
    /// that lands it at the caret instead of at the end, and keeps the field's own undo.
    func newlineOnModifiedReturn() -> some View {
        onKeyPress(phases: .down) { press in
            guard press.key == .return,
                  ReturnKey.insertsNewline(
                      shift: press.modifiers.contains(.shift),
                      option: press.modifiers.contains(.option),
                      command: press.modifiers.contains(.command),
                      control: press.modifiers.contains(.control)
                  ),
                  let editor = NSApp.keyWindow?.firstResponder as? NSTextView
            else { return .ignored }
            editor.insertNewlineIgnoringFieldEditor(nil)
            return .handled
        }
    }

    func keyboardFocusRingOnly() -> some View {
        let assistiveTechRunning = NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
        return focusEffectDisabled(!assistiveTechRunning)
    }
}

/// The 1pt line between grouped rows — the card editor's row separator, now shared with the
/// card face so both read as the same control.
struct HairlineDivider: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, 10)
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
    var identifier: String?

    init(
        prompt: String,
        text: Binding<String>,
        focused: FocusState<Bool>.Binding? = nil,
        identifier: String? = nil
    ) {
        self.prompt = prompt
        _text = text
        self.focused = focused
        self.identifier = identifier
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            if let focused {
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .focused(focused)
                    .accessibilityIdentifier(identifier ?? prompt)
            } else {
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier(identifier ?? prompt)
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

// MARK: - RGBAColor <-> SwiftUI Color

extension Color {
    init(_ c: RGBAColor) {
        self.init(red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
}

extension RGBAColor {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }
}
