import SwiftUI
import Combine

/// "now", "5 minutes ago", "yesterday" — named units via RelativeDateTimeFormatter,
/// refreshed once per minute instead of SwiftUI's every-second `.relative` style.
///
/// A plain `Text` on a shared minute tick, not a `TimelineView(.everyMinute)`: a new note's
/// row was reported coming up one line tall, its date only appearing later — the timeline's
/// content is the one part of the row that can draw empty. Not reproduced on macOS 26.6 (the
/// mini); seen on 27. A `Text` built in `body` has its string from the first frame.
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
