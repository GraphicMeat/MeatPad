import SwiftUI

/// "now", "5 minutes ago", "yesterday" — named units via RelativeDateTimeFormatter,
/// refreshed once per minute instead of SwiftUI's every-second `.relative` style.
struct RelativeTimeText: View {
    let date: Date

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter
    }()

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(Self.label(for: date, now: context.date))
        }
    }

    private static func label(for date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "now" }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
