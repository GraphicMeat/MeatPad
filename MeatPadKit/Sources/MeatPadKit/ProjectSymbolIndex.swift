import Foundation

/// Project-wide identifier index for completion: walks a file list, tokenizes
/// each file's text into identifier words, and serves prefix lookups ranked
/// by total frequency. Builds run off-main (concurrent per-file reads, same
/// pattern as `NativeSearch`); lookups and incremental updates are
/// synchronous against the latest built snapshot so the completion path never
/// touches disk.
public final class ProjectSymbolIndex: @unchecked Sendable {
    private let maxFileSize = 4_000_000

    // ponytail: single global lock guarding the whole snapshot rather than
    // per-file locks — updateFile/removeFile/complete are all main-thread
    // callers per the plan, build() only writes once per file via a merge
    // step below, so contention is a non-issue. Revisit if a future caller
    // needs concurrent lookups from multiple threads at high frequency.
    private let lock = NSLock()
    private var wordCounts: [URL: [String: Int]] = [:] // per-file word -> count
    private var buildGeneration = 0

    public init() {}

    /// Full build: reads and tokenizes `files` concurrently, then replaces the
    /// entire snapshot. Cancellable — checked between files; a cancelled build
    /// still installs whatever it collected before cancellation, since a
    /// superseding `build` call (newer generation) always wins over a stale one.
    public func build(files: [URL]) async {
        let generation: Int = {
            lock.lock()
            defer { lock.unlock() }
            buildGeneration += 1
            return buildGeneration
        }()

        var collected: [URL: [String: Int]] = [:]
        await withTaskGroup(of: (URL, [String: Int]?).self) { group in
            for file in files {
                if Task.isCancelled { break } // checked between files per NativeSearch precedent
                let maxFileSize = maxFileSize
                group.addTask {
                    (file, Self.tokenize(file, maxFileSize: maxFileSize))
                }
            }
            for await (file, counts) in group {
                if let counts { collected[file] = counts }
            }
        }

        install(collected, generation: generation)
    }

    /// Synchronous install of a completed build's snapshot, guarded by `lock`.
    /// Kept as an ordinary (non-async) function so the lock is never held
    /// across a suspension point — calling `NSLock.lock()/unlock()` directly
    /// inside an `async` function is unavailable in Swift 6 language mode.
    private func install(_ collected: [URL: [String: Int]], generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        // A newer build superseded this one while we were reading files; drop our result.
        guard generation == buildGeneration else { return }
        wordCounts = collected
    }

    /// Replaces one file's contribution (FSEvents incremental change).
    /// Removes it entirely when the file is unreadable, binary, or oversize.
    public func updateFile(_ url: URL) {
        let counts = Self.tokenize(url, maxFileSize: maxFileSize)
        lock.lock()
        defer { lock.unlock() }
        if let counts, !counts.isEmpty {
            wordCounts[url] = counts
        } else {
            wordCounts.removeValue(forKey: url)
        }
    }

    /// Drops a file's contribution entirely (deleted from disk).
    public func removeFile(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        wordCounts.removeValue(forKey: url)
    }

    /// Synchronous snapshot lookup: identifiers starting with `prefix`
    /// (case-insensitive), ranked by total frequency descending, ties broken
    /// alphabetically for determinism. Words contributed only by
    /// `excludingFile` are omitted; words shared with at least one other file
    /// keep their full total (excludingFile's own count subtracted). Output
    /// preserves the exact-case spelling with the highest count.
    public func complete(prefix: String, excludingFile: URL?, limit: Int) -> [String] {
        let lowerPrefix = prefix.lowercased()

        lock.lock()
        let snapshot = wordCounts
        lock.unlock()

        // Merge per-file counts into: total frequency (excluding the excluded
        // file's contribution) and, per lowercased key, the best-count exact-case spelling.
        var totals: [String: Int] = [:] // keyed by lowercased word
        var bestSpelling: [String: (word: String, count: Int)] = [:] // keyed by lowercased word

        for (file, counts) in snapshot {
            for (word, count) in counts {
                let lower = word.lowercased()
                guard lowerPrefix.isEmpty || lower.hasPrefix(lowerPrefix) else { continue }

                if file != excludingFile {
                    totals[lower, default: 0] += count
                }

                if let current = bestSpelling[lower] {
                    // Deterministic tiebreak: higher count wins; on an equal
                    // count, the lexicographically smaller spelling wins
                    // (dictionary iteration order over `snapshot` is
                    // otherwise unspecified, which made this non-deterministic
                    // across builds when two files tie on count).
                    if count > current.count || (count == current.count && word < current.word) {
                        bestSpelling[lower] = (word, count)
                    }
                } else {
                    bestSpelling[lower] = (word, count)
                }
            }
        }

        let ranked = totals.keys.sorted { a, b in
            let ta = totals[a]!
            let tb = totals[b]!
            if ta != tb { return ta > tb }
            return a < b
        }

        return ranked.prefix(limit).map { bestSpelling[$0]!.word }
    }

    /// Reads and tokenizes one file per the `NativeSearch` read pattern: size
    /// cap, binary skip (NUL in first 8KB), UTF-8 decode or skip. Returns nil
    /// when the file is unreadable/binary/oversize.
    private static func tokenize(_ url: URL, maxFileSize: Int) -> [String: Int]? {
        guard fileSize(url) <= maxFileSize else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard !isBinary(data) else { return nil }
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        var counts: [String: Int] = [:]
        IdentifierScan.words(in: content) { word, _, _ in
            guard word.count >= 3 else { return } // ponytail: 1-2 char identifiers are noise
            counts[word, default: 0] += 1
        }
        return counts
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    private static func isBinary(_ data: Data) -> Bool {
        data.prefix(8192).contains(0)
    }
}
