/// Which fold heads deserve a gutter chevron right now.
///
/// A gutter marker only draws on a line that has a laid-out number cell, i.e. a visible one, yet
/// adding a marker re-lays-out every marker already present — so giving every head of a huge file
/// a chevron is quadratic (a 3 MB source file hung the app on open). Only heads near the viewport
/// get one.
public enum ChevronWindow {
    /// Indices into `headOffsets` (ascending UTF-16 offsets) of heads within `margin` of `viewport`.
    public static func indices(headOffsets: [Int], viewport: Range<Int>, margin: Int) -> Range<Int> {
        let lower = firstIndex(in: headOffsets) { $0 >= viewport.lowerBound - margin }
        let upper = firstIndex(in: headOffsets) { $0 > viewport.upperBound + margin }
        return lower..<max(lower, upper)
    }

    private static func firstIndex(in offsets: [Int], where predicate: (Int) -> Bool) -> Int {
        var low = 0, high = offsets.count
        while low < high {
            let mid = low + (high - low) / 2
            if predicate(offsets[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
