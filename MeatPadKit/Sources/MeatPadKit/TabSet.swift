import Foundation

/// Which tabs a tab's "Close Others" / "Close to the Right" act on.
public enum TabSet {
    /// Every open tab except `tab`, in tab order.
    public static func others(than tab: URL, in tabs: [URL]) -> [URL] {
        tabs.filter { $0 != tab }
    }

    /// The tabs after `tab`, in tab order. Empty for the last tab, or one that isn't open.
    public static func toTheRight(of tab: URL, in tabs: [URL]) -> [URL] {
        guard let index = tabs.firstIndex(of: tab) else { return [] }
        return Array(tabs[(index + 1)...])
    }
}
