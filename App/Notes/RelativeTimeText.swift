import SwiftUI
import Combine

/// "now", "5 minutes ago", "yesterday" — named units via RelativeDateTimeFormatter,
/// refreshed once per minute instead of SwiftUI's every-second `.relative` style.
///
/// A plain `Text` on a shared minute tick, not a `TimelineView(.everyMinute)`, so the string is
/// there from the first frame. Rows coming up one line tall on macOS 27 outlived that change:
/// the row height was the fault, guarded by `defaultMinListRowHeight` on the lists.
struct RelativeTimeText: View {
    let date: Date
    @State private var now = Date()

    private static let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter
    }()

    var body: some View {
        Text(Self.label(for: date, now: now))
            .onReceive(Self.tick) { now = $0 }
    }

    private static func label(for date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return String(localized: "now") }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
