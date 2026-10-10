import Foundation

/// A folder Credo scans (recursively) for *.jsonl transcripts.
public struct ScanRoot: Sendable, Hashable {
    public var url: URL
    public var label: String
    /// When set, every record under this root is attributed to this tool.
    public var sourceHint: UsageSource?
}

/// Incrementally reads Claude Code / Claude Desktop JSONL transcripts, de-duplicates
/// API calls, keeps a private history file and produces aggregated snapshots.
/// All public methods are thread-safe; call them from a background queue.
public final class UsageEngine: @unchecked Sendable {

    private struct FileState {
        var offset: UInt64 = 0
        var pending = Data()
    }

    private let lock = NSLock()
    private let supportDir: URL?
    private var files: [String: FileState] = [:]
    private var records: [String: UsageRecord] = [:]
    private var pricing = PricingTable()
    private var pricingModDate: Date?
    private var forcePricingReload = false
    private var historyLoaded = false
    private var unsavedHistory: [UsageRecord] = []
    private var dirty = true
    private var cached: UsageSnapshot?
    private var cachedHour = -1
    private var cachedWindow: WindowOverride?
    private var cachedBlockActive = false

    private let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain = ISO8601DateFormatter()

    private static let usageMarker = Data("\"usage\"".utf8)

    /// Chromium/Electron caches and bundles inside Claude Desktop's folder that never hold transcripts.
    private static let skipDirectories: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "IndexedDB", "Local Storage", "Session Storage", "Service Worker", "blob_storage",
        "Crashpad", "Shared Dictionary", "WebStorage", "Network", "shared_proto_db",
        "VideoDecodeStats", "Partitions", "node_modules", "vm_bundles", "Claude Extensions",
        "Extensions", "logs", "sentry"
    ]

    public init(supportDirectory: URL?) {
        self.supportDir = supportDirectory
    }

    public var pricingURL: URL? { supportDir?.appendingPathComponent("pricing.json") }
    // v2: records keyed by message id, tools split into terminal / VS Code / Code tab / agent.
    private var historyURL: URL? { supportDir?.appendingPathComponent("history-v2.tsv") }
    private var legacyHistoryURL: URL? { supportDir?.appendingPathComponent("history.tsv") }

    // MARK: - Roots

    public static func defaultRoots(extraFolders: [String]) -> [ScanRoot] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var roots: [ScanRoot] = []

        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            for part in env.split(separator: ",") {
                let base = URL(fileURLWithPath: (String(part).trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath)
                roots.append(ScanRoot(url: base.appendingPathComponent("projects"), label: "Claude Code (CLAUDE_CONFIG_DIR)", sourceHint: nil))
            }
        }
        roots.append(ScanRoot(url: home.appendingPathComponent(".claude/projects"), label: "Claude Code (~/.claude)", sourceHint: nil))
        roots.append(ScanRoot(url: home.appendingPathComponent(".config/claude/projects"), label: "Claude Code (~/.config/claude)", sourceHint: nil))
        roots.append(ScanRoot(url: home.appendingPathComponent("Library/Application Support/Claude"), label: "Claude Desktop", sourceHint: .desktopAgent))
        for folder in extraFolders where !folder.isEmpty {
            let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
            roots.append(ScanRoot(url: url, label: "Custom folder", sourceHint: nil))
        }

        var seen = Set<String>()
        return roots.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
    }

    /// Log folders of OpenAI and Google tools. Credo shows whether they exist and how many log
    /// files they hold, but doesn't parse them yet.
    static func plannedRootStatuses() -> [RootStatus] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let planned: [(String, String, Provider)] = [
            ("Codex CLI", ".codex/sessions", .openai),
            ("Gemini CLI", ".gemini", .google)
        ]
        return planned.map { label, relative, provider in
            let url = home.appendingPathComponent(relative)
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            return RootStatus(path: url.path, label: label, exists: exists,
                              fileCount: exists ? countLogFiles(in: url) : 0,
                              provider: provider, isTracked: false)
        }
    }

    /// Counts .jsonl / .json files (up to a cap) without reading them.
    static func countLogFiles(in root: URL, cap: Int = 5000) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            if url.lastPathComponent == "node_modules" { enumerator.skipDescendants(); continue }
            let ext = url.pathExtension.lowercased()
            if ext == "jsonl" || ext == "json" {
                count += 1
                if count >= cap { break }
            }
        }
        return count
    }

    // MARK: - Public API

    /// `window` places the 5-hour window from Claude's own reset time (Sync with Claude account);
    /// nil works it out from the logs.
    public func refresh(extraFolders: [String], window: WindowOverride? = nil, now: Date = Date()) -> UsageSnapshot {
        lock.lock()
        defer { lock.unlock() }

        ensureSupportFiles()
        reloadPricingIfNeeded()
        loadHistoryIfNeeded()

        var statuses: [RootStatus] = []
        var totalFiles = 0
        for root in Self.defaultRoots(extraFolders: extraFolders) {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: root.url.path, isDirectory: &isDir) && isDir.boolValue
            var count = 0
            if exists {
                for file in jsonlFiles(in: root.url) {
                    process(file: file, root: root)
                    count += 1
                }
            }
            statuses.append(RootStatus(path: root.url.path, label: root.label, exists: exists, fileCount: count))
            totalFiles += count
        }
        statuses += Self.plannedRootStatuses()
        flushHistory()

        // Reuse the last snapshot only within the same local hour (so Today rolls over at local
        // midnight, including in half-hour time zones) and while the 5-hour window hasn't ended.
        let offset = Double(TimeZone.current.secondsFromGMT(for: now))
        let hour = Int(((now.timeIntervalSince1970 + offset) / 3600).rounded(.down))
        if !dirty, let cached, cachedHour == hour, cachedWindow == window, cached.roots == statuses,
           (cached.block?.isActive(at: now) ?? false) == cachedBlockActive {
            return cached
        }
        let snap = Aggregator.snapshot(records: Array(records.values), roots: statuses, fileCount: totalFiles,
                                      window: window, now: now)
        cached = snap
        cachedHour = hour
        cachedWindow = window
        cachedBlockActive = snap.block?.isActive(at: now) ?? false
        dirty = false
        return snap
    }

    /// Re-read every log from the beginning (history is kept; duplicates are ignored).
    public func resetScanState() {
        lock.lock(); defer { lock.unlock() }
        files.removeAll()
        dirty = true
    }

    /// Forget all saved history and start over from whatever logs exist now.
    public func clearHistory() {
        lock.lock(); defer { lock.unlock() }
        files.removeAll()
        records.removeAll()
        unsavedHistory.removeAll()
        if let url = historyURL { try? FileManager.default.removeItem(at: url) }
        historyLoaded = true
        dirty = true
    }

    public func reloadPricing() {
        lock.lock(); defer { lock.unlock() }
        forcePricingReload = true
    }

    // MARK: - Files

    private func ensureSupportFiles() {
        guard let dir = supportDir, let pricingURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: pricingURL.path) {
            try? PricingTable.writeDefaults(to: pricingURL)
        }
    }

    private func reloadPricingIfNeeded() {
        let mod = pricingURL.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
        guard forcePricingReload || mod != pricingModDate else { return }
        forcePricingReload = false
        pricingModDate = mod
        pricing = PricingTable.load(from: pricingURL)
        records = records.mapValues { r in
            var copy = r
            copy.cost = pricing.cost(r)
            copy.saved = pricing.cacheSavings(r)
            return copy
        }
        dirty = true
    }

    private func jsonlFiles(in root: URL) -> [URL] {
        var out: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { _, _ in true }) else { return out }

        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if Self.skipDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            if url.pathExtension.lowercased() == "jsonl" { out.append(url) }
        }
        return out
    }

    private func process(file url: URL, root: ScanRoot) {
        let path = url.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let sizeNumber = attrs[.size] as? NSNumber else { return }
        let size = sizeNumber.uint64Value
        let modDate = (attrs[.modificationDate] as? Date) ?? Date()

        var state = files[path] ?? FileState()
        if size < state.offset { state = FileState() }      // file was rewritten: read again, dedupe handles overlap
        if size == state.offset && state.pending.isEmpty {
            files[path] = state
            return
        }

        var buffer = state.pending
        if size > state.offset {
            guard let fh = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? fh.close() }
            do {
                try fh.seek(toOffset: state.offset)
                if let data = try fh.readToEnd() {
                    buffer.append(data)
                    state.offset += UInt64(data.count)
                }
            } catch {
                return
            }
        }

        var lineStart = buffer.startIndex
        while lineStart < buffer.endIndex, let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
            if newline > lineStart {
                handle(line: Data(buffer[lineStart..<newline]), file: url, root: root, fallbackDate: modDate, needValidity: false)
            }
            lineStart = buffer.index(after: newline)
        }

        // The last line may still be being written. Keep it unless it already parses.
        var rest = Data(buffer[lineStart...])
        if !rest.isEmpty, handle(line: rest, file: url, root: root, fallbackDate: modDate, needValidity: true) {
            rest = Data()
        }
        state.pending = rest
        files[path] = state
    }

    /// Returns true when the line was complete JSON (whether or not it contained usage).
    /// Validity is only computed for usage-free lines when `needValidity` is set (the trailing line).
    @discardableResult
    private func handle(line: Data, file: URL, root: ScanRoot, fallbackDate: Date, needValidity: Bool) -> Bool {
        guard line.range(of: Self.usageMarker) != nil else {
            return needValidity ? (try? JSONSerialization.jsonObject(with: line)) != nil : true
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return false }

        let type = obj["type"] as? String
        if type == "result" || type == "summary" { return true }   // session aggregates — would double count
        guard let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return true }
        if let role = message["role"] as? String, role != "assistant" { return true }

        let model = (message["model"] as? String) ?? "unknown"
        if model == "<synthetic>" { return true }

        func int(_ dict: [String: Any], _ key: String) -> Int { (dict[key] as? NSNumber)?.intValue ?? 0 }
        let input = int(usage, "input_tokens")
        let output = int(usage, "output_tokens")
        let cacheRead = int(usage, "cache_read_input_tokens")
        let cacheCreate = int(usage, "cache_creation_input_tokens")
        var write5m = cacheCreate
        var write1h = 0
        if let detail = usage["cache_creation"] as? [String: Any] {
            let a = int(detail, "ephemeral_5m_input_tokens")
            let b = int(detail, "ephemeral_1h_input_tokens")
            if a + b > 0 { write5m = a; write1h = b }
        }
        guard input + output + cacheRead + write5m + write1h > 0 else { return true }

        let parsedDate = parseDate(obj["timestamp"])
        let timestamp = parsedDate ?? fallbackDate
        let sessionId = (obj["sessionId"] as? String) ?? (obj["session_id"] as? String)
            ?? (file.deletingLastPathComponent().lastPathComponent + "/" + file.deletingPathExtension().lastPathComponent)
        let messageId = message["id"] as? String
        let requestId = (obj["requestId"] as? String) ?? (obj["request_id"] as? String)

        // One API response = one message id. Claude Code writes a line per content block
        // (thinking / text / tool call) repeating the same usage, and Desktop agent sessions
        // keep a second copy of each response, so the message id alone is the dedupe key.
        let key: String
        if let messageId, !messageId.isEmpty {
            key = "msg:\(messageId)"
        } else if let requestId, !requestId.isEmpty {
            key = "req:\(requestId)"
        } else {
            key = "\(file.path)|\(timestamp.timeIntervalSince1970)|\(input)|\(output)|\(cacheRead)|\(cacheCreate)"
        }

        var record = UsageRecord(
            key: key,
            timestamp: timestamp,
            source: classify(hint: root.sourceHint, entrypoint: obj["entrypoint"] as? String, file: file),
            model: model,
            project: projectName(cwd: obj["cwd"] as? String, file: file, root: root),
            sessionId: sessionId,
            input: input,
            output: output,
            cacheWrite5m: write5m,
            cacheWrite1h: write1h,
            cacheRead: cacheRead)
        record.cost = pricing.cost(record)
        record.saved = pricing.cacheSavings(record)
        record.timestampKnown = parsedDate != nil
        insert(record, persist: true)
        return true
    }

    private func insert(_ incoming: UsageRecord, persist: Bool) {
        var record = incoming
        if let existing = records[record.key] {
            // Streaming writes the same message several times; keep the most complete counts.
            let better = record.output > existing.output
                || (record.output == existing.output && record.total > existing.total)
            if existing.timestampKnown == record.timestampKnown {
                guard better else { return }
            } else {
                // One copy has a real timestamp and the other doesn't: keep the real timestamp
                // together with whichever copy has the fuller token counts.
                let timed = record.timestampKnown ? record : existing
                var merged = better ? record : existing
                merged.timestamp = timed.timestamp
                merged.timestampKnown = true
                if existing.timestampKnown && merged.timestamp == existing.timestamp
                    && merged.output == existing.output && merged.total == existing.total {
                    return
                }
                record = merged
            }
        }
        records[record.key] = record
        dirty = true
        // Only records with a real timestamp go into the history file.
        if persist && record.timestampKnown { unsavedHistory.append(record) }
    }

    private func classify(hint: UsageSource?, entrypoint: String?, file: URL) -> UsageSource {
        let e = (entrypoint ?? "").lowercased()
        if e.contains("local-agent") || file.path.contains("/local-agent-mode-sessions/") { return .desktopAgent }
        if e.contains("vscode") || e.contains("cursor") || e.contains("jetbrains") { return .vscode }
        if e.contains("desktop") { return .desktopCode }
        if e.hasPrefix("sdk") { return .agentSDK }
        if e == "cli" { return .claudeCodeCLI }
        if let hint { return hint }
        return .claudeCodeCLI
    }

    private func projectName(cwd: String?, file: URL, root: ScanRoot) -> String {
        if let cwd, !cwd.isEmpty {
            if cwd == FileManager.default.homeDirectoryForCurrentUser.path { return "~ (home)" }
            let last = URL(fileURLWithPath: cwd).lastPathComponent
            return last.isEmpty ? cwd : last
        }
        if root.sourceHint == .desktopAgent { return "Desktop agent sessions" }
        // Claude Code stores transcripts under projects/<cwd with / replaced by ->/
        let relative = file.path.dropFirst(root.url.path.count).split(separator: "/")
        if let folder = relative.first, relative.count > 1,
           let last = folder.split(separator: "-").last {
            return String(last)
        }
        return "Unknown"
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let s = value as? String {
            return isoFractional.date(from: s) ?? isoPlain.date(from: s)
        }
        if let n = value as? NSNumber {
            let v = n.doubleValue
            return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
        }
        return nil
    }

    // MARK: - History (survives Claude Code's automatic transcript cleanup)

    private func loadHistoryIfNeeded() {
        guard !historyLoaded else { return }
        historyLoaded = true
        // v1 history used different keys and tool labels; it is rebuilt from the logs.
        if let legacy = legacyHistoryURL { try? FileManager.default.removeItem(at: legacy) }
        guard let url = historyURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 11, let ts = Double(f[1]), let source = UsageSource(rawValue: String(f[2])) else { continue }
            var r = UsageRecord(
                key: String(f[0]),
                timestamp: Date(timeIntervalSince1970: ts),
                source: source,
                model: String(f[3]),
                project: String(f[4]),
                sessionId: String(f[5]),
                input: Int(f[6]) ?? 0,
                output: Int(f[7]) ?? 0,
                cacheWrite5m: Int(f[8]) ?? 0,
                cacheWrite1h: Int(f[9]) ?? 0,
                cacheRead: Int(f[10]) ?? 0)
            r.cost = pricing.cost(r)
            r.saved = pricing.cacheSavings(r)
            insert(r, persist: false)
        }
    }

    private func flushHistory() {
        guard !unsavedHistory.isEmpty, let url = historyURL else { return }
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        var out = ""
        out.reserveCapacity(unsavedHistory.count * 160)
        for r in unsavedHistory {
            out += [clean(r.key), String(r.timestamp.timeIntervalSince1970), r.source.rawValue,
                    clean(r.model), clean(r.project), clean(r.sessionId),
                    String(r.input), String(r.output), String(r.cacheWrite5m),
                    String(r.cacheWrite1h), String(r.cacheRead)].joined(separator: "\t")
            out += "\n"
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data(out.utf8))
            unsavedHistory.removeAll()
        } catch {
            // keep unsaved records for the next attempt
        }
    }
}
