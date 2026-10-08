import Foundation

/// Project-wide identifier index for completion: walks a file list, tokenizes
/// each file's text into identifier words, and serves prefix lookups ranked
/// by total frequency. Builds run off-main (concurrent per-file reads, same
/// pattern as `NativeSearch`); lookups and incremental updates are
/// synchronous against the latest built snapshot so the completion path never
/// touches disk.
public final class ProjectSymbolIndex: @unchecked Sendable {
    /// Bounds what the index keeps in RAM: per-file word tables dominate, so cap both file size and file count.
    private let maxFileSize = 1_000_000
    private let maxFiles: Int

    // ponytail: single global lock guarding the whole snapshot rather than
    // per-file locks — updateFile/removeFile/complete are all main-thread
    // callers per the plan, build() only writes once per file via a merge
    // step below, so contention is a non-issue. Revisit if a future caller
    // needs concurrent lookups from multiple threads at high frequency.
    private let lock = NSLock()
    private var wordCounts: [URL: [String: Int]] = [:] // per-file word -> count
    private var buildGeneration = 0

    public init(maxFiles: Int = 2_000) {
        self.maxFiles = maxFiles
    }

    /// True when `url` already has a table in the index.
    public func isIndexed(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return wordCounts[url] != nil
    }

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

        let collected = await Self.tokenizeAll(Array(files.prefix(maxFiles)), maxFileSize: maxFileSize)

        install(collected, generation: generation)
    }

    /// Incremental: reads and tokenizes only the files not indexed yet and merges them in, leaving
    /// the rest of the snapshot alone. New files beyond `maxFiles` are dropped unless
    /// `ignoringLimit` (open tabs always get indexed).
    public func add(files: [URL], ignoringLimit: Bool = false) async {
        let fresh = files.filter { !isIndexed($0) }
        guard !fresh.isEmpty else { return }
        let collected = await Self.tokenizeAll(fresh, maxFileSize: maxFileSize)
        merge(collected, ignoringLimit: ignoringLimit)
    }

    private func merge(_ collected: [URL: [String: Int]], ignoringLimit: Bool) {
        lock.lock()
        defer { lock.unlock() }
        for (file, counts) in collected where !counts.isEmpty {
            if ignoringLimit || wordCounts.count < maxFiles || wordCounts[file] != nil {
                wordCounts[file] = counts
            }
        }
    }

    private static func tokenizeAll(_ files: [URL], maxFileSize: Int) async -> [URL: [String: Int]] {
        var collected: [URL: [String: Int]] = [:]
        await withTaskGroup(of: (URL, [String: Int]?).self) { group in
            for file in files {
                if Task.isCancelled { break } // checked between files per NativeSearch precedent
                group.addTask {
                    (file, tokenize(file, maxFileSize: maxFileSize))
                }
            }
            for await (file, counts) in group {
                if let counts { collected[file] = counts }
            }
        }
        return collected
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
