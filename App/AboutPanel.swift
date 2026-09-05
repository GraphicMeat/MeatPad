import AppKit

/// The About panel. macOS's standard one, with the studio's mark and a link home spliced
/// into its credits field — a custom window would be one more thing to keep in step with
/// the system's own (dark mode, text size, the Sparkle item sitting under it).
enum AboutPanel {
    static let studio = URL(string: "https://graphicmeat.com")!

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// The lockup over the address, centred under the version line. The lockup carries the
    /// studio's name and tagline itself, so the only text here is the link — the name also
    /// signs the copyright line below it.
    private static var credits: NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.paragraphSpacing = 4

        let text = NSMutableAttributedString()
        if let mark = NSImage(named: "GraphicMeatLogo") {
            // The source is 420pt wide at 1x, which would set the panel's width on its own;
            // this sits just under the app icon above it, which is the panel's subject.
            mark.size = NSSize(width: 108, height: 92)
            let attachment = NSTextAttachment()
            attachment.image = mark
            attachment.bounds = CGRect(origin: .zero, size: mark.size)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: "\n"))
        }
        text.append(NSAttributedString(string: "graphicmeat.com", attributes: [
            .link: studio,
            .font: NSFont.systemFont(ofSize: 11),
        ]))
        text.addAttribute(
            .paragraphStyle,
            value: centred,
            range: NSRange(location: 0, length: text.length)
        )
        return text
    }
}
