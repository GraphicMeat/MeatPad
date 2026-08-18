import Combine
import Foundation
import UserNotifications
import MeatPadKit

/// Replays `BoardStore.pendingDueReminders()` into UNUserNotificationCenter. Which cards
/// deserve a reminder is decided in MeatPadKit (pure and unit-tested); this only schedules.
///
/// It subscribes to the store rather than being called from each mutation site: every move,
/// edit, delete, and done-column change already goes through `objectWillChange`, so one
/// debounced observer can't drift out of sync the way a dozen call sites would.
@MainActor
final class DueNotifier {
    static let shared = DueNotifier()

    private let center = UNUserNotificationCenter.current()
    private var cancellable: AnyCancellable?
    private let debouncer = Debouncer(delay: 0.5)

    /// Called once from `AppModel.init`: reschedules everything still pending at launch and
    /// keeps it in step for the rest of the session.
    func start(store: BoardStore) {
        cancellable = store.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the mutation lands; the debounce also lets the
            // value settle before it is read back.
            self?.debouncer.call { [weak self] in
                Task { await self?.reconcile(store: store) }
            }
        }
        Task { await reconcile(store: store) }
    }

    /// Asked the first time the user sets a due date — never at launch. A no-account app
    /// shouldn't greet a new user with a system prompt.
    func requestAuthorizationIfNeeded() async {
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Drops every card request and re-adds the ones still pending. Cards are few, so a full
    /// reconcile is cheaper than tracking deltas — and immune to drift.
    func reconcile(store: BoardStore) async {
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        let reminders = store.pendingDueReminders()
        let live = Set(reminders.map(\.cardID.uuidString))
        let stale = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { !live.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Card due")
            content.body = reminder.title
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.due)
            let request = UNNotificationRequest(
                identifier: reminder.cardID.uuidString,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            // Re-adding an existing identifier replaces it, which is exactly what an edited
            // due date needs.
            try? await center.add(request)
        }
    }

    /// Privacy erase-all: pending reminders are card data too.
    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }
}
