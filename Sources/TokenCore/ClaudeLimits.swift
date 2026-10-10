import Foundation

/// One of Claude's plan limits as Claude Code's `/usage` shows it.
public struct LimitWindow: Sendable, Equatable {
    /// Share of the limit used, 0...1 (can go past 1).
    public var used: Double
    /// When this limit resets. Nil when no window is running.
    public var resetsAt: Date?

    public init(used: Double, resetsAt: Date?) {
        self.used = used
        self.resetsAt = resetsAt
    }
}

/// Claude's own usage limits, read from Claude's servers. They count every surface
/// (web, desktop and mobile chats, Claude Code, Claude Design, cloud sessions).
public struct ClaudeLimits: Sendable, Equatable {
    public var fiveHour: LimitWindow?
    public var sevenDay: LimitWindow?
    public var fetchedAt: Date

    public init(fiveHour: LimitWindow?, sevenDay: LimitWindow?, fetchedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.fetchedAt = fetchedAt
    }

    /// Start of Claude's current 5-hour window (its reset time minus five hours), or nil
    /// when Claude reports no running window.
    public func sessionStart(at now: Date) -> Date? {
        guard let reset = fiveHour?.resetsAt, reset > now else { return nil }
        return reset.addingTimeInterval(-BlockInfo.length)
    }

    /// The weekly limit, while its reset time is still ahead.
    public func week(at now: Date) -> LimitWindow? {
        guard let w = sevenDay, let reset = w.resetsAt, reset > now else { return nil }
        return w
    }
}

/// How Credo should place the 5-hour window.
public enum WindowOverride: Sendable, Equatable {
    /// Claude says a window started at this time.
    case start(Date)
    /// Claude says no window is running.
    case noWindow
}

public enum LimitsError: Error, Equatable, Sendable {
    case notSignedIn
    case expired
    case unauthorized
    case rateLimited
    case http(Int)
    case network(String)
    case badResponse

    public var message: String {
        switch self {
        case .notSignedIn: return "Claude Code isn't signed in on this Mac. Run `claude` and log in with your Claude plan."
        case .expired: return "Claude Code's sign-in has expired. Open Claude Code (run `claude`) once to refresh it."
        case .unauthorized: return "Claude refused the sign-in. Open Claude Code (run `claude`) to refresh it."
        case .rateLimited: return "Claude asked Credo to slow down. Retrying in a few minutes."
        case .http(let code): return "Claude's usage service returned an error (HTTP \(code))."
        case .network(let text): return "Couldn't reach Claude: \(text)"
        case .badResponse: return "Claude's usage service sent something Credo doesn't understand. It may have changed."
        }
    }
}

/// Reads Claude's limits the way Claude Code's `/usage` does: Claude Code's sign-in from the
/// macOS Keychain, then one GET to Claude's usage endpoint.
///
/// The endpoint is unofficial and undocumented, so it may change. Credo only reads usage with it.
/// It never renews the sign-in (that could log Claude Code out) and never sends the token
/// anywhere except api.anthropic.com.
public enum ClaudeLimitsClient {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let keychainService = "Claude Code-credentials"

    struct Credentials {
        var token: String
        var expiresAt: Date?
    }

    // MARK: Credentials

    /// Claude Code keeps its sign-in in the login Keychain on macOS, or in
    /// `.credentials.json` in its config folder on other setups.
    static func readCredentials() -> Credentials? {
        if let data = keychainData(), let c = parseCredentials(data) { return c }
        let fm = FileManager.default
        var dirs: [URL] = []
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            dirs.append(URL(fileURLWithPath: (custom as NSString).expandingTildeInPath))
        }
        let home = fm.homeDirectoryForCurrentUser
        dirs.append(home.appendingPathComponent(".claude"))
        dirs.append(home.appendingPathComponent(".config/claude"))
        for dir in dirs {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(".credentials.json")),
               let c = parseCredentials(data) {
                return c
            }
        }
        return nil
    }

    /// Asks macOS's own `security` tool for the item. Claude Code saves its sign-in with that
    /// tool, so reading it this way normally needs no extra Keychain prompt.
    static func keychainData() -> Data? {
        let tool = "/usr/bin/security"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        // `-w` prints the secret followed by a newline.
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Data(trimmed.utf8)
    }

    static func parseCredentials(_ data: Data) -> Credentials? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double {
            // Milliseconds since 1970 (older files used seconds).
            expires = Date(timeIntervalSince1970: ms > 1e12 ? ms / 1000 : ms)
        }
        return Credentials(token: token, expiresAt: expires)
    }

    // MARK: Response

    /// Parses `{"five_hour": {"utilization": 21.0, "resets_at": "…"}, "seven_day": {…}}`.
    /// `utilization` is a percentage.
    public static func parse(_ data: Data, now: Date = Date()) throws -> ClaudeLimits {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitsError.badResponse
        }
        if obj["error"] != nil { throw LimitsError.badResponse }
        func window(_ key: String) -> LimitWindow? {
            guard let w = obj[key] as? [String: Any] else { return nil }
            let pct = (w["utilization"] as? Double) ?? (w["utilization"] as? Int).map(Double.init)
            guard let pct else { return nil }
            // Reset times arrive just before the hour (…:59:59.94); round to the minute.
            let reset = (w["resets_at"] as? String).flatMap(parseDate)
                .map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded() * 60) }
            return LimitWindow(used: pct / 100, resetsAt: reset)
        }
        let five = window("five_hour")
        let week = window("seven_day")
        if five == nil && week == nil && obj["five_hour"] == nil { throw LimitsError.badResponse }
        return ClaudeLimits(fiveHour: five, sevenDay: week, fetchedAt: now)
    }

    /// ISO 8601 with any number of fractional digits, e.g. `2026-10-10T18:59:59.943648+00:00`.
    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        var text = s
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            let digits = text.index(after: dot)
            let end = text[digits...].firstIndex(where: { !$0.isNumber }) ?? text.endIndex
            fraction = Double("0" + String(text[dot..<end])) ?? 0
            text.removeSubrange(dot..<end)
        }
        return f.date(from: text).map { $0.addingTimeInterval(fraction) }
    }

    // MARK: Fetch

    public static func fetch(now: Date = Date(), timeout: TimeInterval = 15,
                             completion: @escaping @Sendable (Result<ClaudeLimits, LimitsError>) -> Void) {
        guard let creds = readCredentials() else { return completion(.failure(.notSignedIn)) }
        if let exp = creds.expiresAt, exp <= now { return completion(.failure(.expired)) }

        var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Credo", forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        session.dataTask(with: req) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            if let error { return completion(.failure(.network(error.localizedDescription))) }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                guard let data else { return completion(.failure(.badResponse)) }
                do { completion(.success(try parse(data, now: Date()))) }
                catch { completion(.failure((error as? LimitsError) ?? .badResponse)) }
            case 401, 403: completion(.failure(.unauthorized))
            case 429: completion(.failure(.rateLimited))
            default: completion(.failure(.http(code)))
            }
        }.resume()
    }

    public static func fetch(now: Date = Date()) async -> Result<ClaudeLimits, LimitsError> {
        await withCheckedContinuation { cont in
            fetch(now: now) { cont.resume(returning: $0) }
        }
    }

    /// Blocking version for `Credo --limits`.
    public static func fetchBlocking() -> Result<ClaudeLimits, LimitsError> {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        fetch { result in
            box.set(result)
            done.signal()
        }
        done.wait()
        return box.get()
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<ClaudeLimits, LimitsError> = .failure(.badResponse)
        func set(_ v: Result<ClaudeLimits, LimitsError>) { lock.lock(); value = v; lock.unlock() }
        func get() -> Result<ClaudeLimits, LimitsError> { lock.lock(); defer { lock.unlock() }; return value }
    }
}
