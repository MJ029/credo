import Foundation

/// USD per million tokens.
public struct ModelPrice: Codable, Sendable, Equatable {
    public var input: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var cacheRead: Double
    public var output: Double

    public init(_ input: Double, _ cacheWrite5m: Double, _ cacheWrite1h: Double, _ cacheRead: Double, _ output: Double) {
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }
}

/// API-list-price table used to estimate the dollar value of token usage.
/// Users can override any entry in ~/Library/Application Support/Credo/pricing.json.
public struct PricingTable: Sendable {
    public struct Tier: Sendable {
        public var promptThreshold: Int
        public var price: ModelPrice
    }

    public private(set) var prices: [String: ModelPrice]
    public private(set) var tiers: [String: Tier]
    private let sortedKeys: [String]

    public init(prices: [String: ModelPrice] = PricingTable.defaultPrices,
                tiers: [String: Tier] = PricingTable.defaultTiers) {
        self.prices = prices
        self.tiers = tiers
        self.sortedKeys = prices.keys.sorted { $0.count > $1.count }
    }

    // Source: platform.claude.com/docs/en/about-claude/pricing (checked 2026-10-10).
    // Order: input, 5m cache write, 1h cache write, cache read, output.
    public static let defaultPrices: [String: ModelPrice] = [
        "claude-fable-5-1": ModelPrice(10, 12.5, 20, 0.25, 50),
        "claude-mythos-5-1": ModelPrice(10, 12.5, 20, 0.25, 50),
        "claude-fable-5": ModelPrice(10, 12.5, 20, 1, 50),
        "claude-mythos-5": ModelPrice(10, 12.5, 20, 1, 50),
        "claude-opus-5-5": ModelPrice(4, 5, 8, 0.20, 20),
        "claude-opus-5": ModelPrice(5, 6.25, 10, 0.50, 25),
        "claude-opus-4-8": ModelPrice(5, 6.25, 10, 0.50, 25),
        "claude-opus-4-7": ModelPrice(5, 6.25, 10, 0.50, 25),
        "claude-opus-4-6": ModelPrice(5, 6.25, 10, 0.50, 25),
        "claude-opus-4-5": ModelPrice(5, 6.25, 10, 0.50, 25),
        "claude-opus-4-1": ModelPrice(15, 18.75, 30, 1.50, 75),
        "claude-opus-4": ModelPrice(15, 18.75, 30, 1.50, 75),
        "claude-sonnet-5-5": ModelPrice(2, 2.5, 4, 0.10, 10),
        "claude-sonnet-5": ModelPrice(2, 2.5, 4, 0.20, 10),
        "claude-sonnet-4-6": ModelPrice(3, 3.75, 6, 0.30, 15),
        "claude-sonnet-4-5": ModelPrice(3, 3.75, 6, 0.30, 15),
        "claude-sonnet-4": ModelPrice(3, 3.75, 6, 0.30, 15),
        "claude-haiku-5-5": ModelPrice(0.10, 0.125, 0.20, 0.01, 0.50),
        "claude-haiku-4-5": ModelPrice(1, 1.25, 2, 0.10, 5),
        "claude-3-7-sonnet": ModelPrice(3, 3.75, 6, 0.30, 15),
        "claude-3-5-sonnet": ModelPrice(3, 3.75, 6, 0.30, 15),
        "claude-3-5-haiku": ModelPrice(0.80, 1, 1.6, 0.08, 4),
        "claude-3-opus": ModelPrice(15, 18.75, 30, 1.50, 75),
        "claude-3-haiku": ModelPrice(0.25, 0.30, 0.50, 0.03, 1.25)
    ]

    /// Haiku 5.5 is billed at a higher rate when the prompt exceeds 100K tokens.
    public static let defaultTiers: [String: Tier] = [
        "claude-haiku-5-5": Tier(promptThreshold: 100_000, price: ModelPrice(0.50, 0.625, 1.0, 0.05, 2.50))
    ]

    /// Unknown future models fall back to the newest price of their family.
    private static let familyFallback: [(String, String)] = [
        ("fable", "claude-fable-5-1"),
        ("mythos", "claude-mythos-5-1"),
        ("opus", "claude-opus-5-5"),
        ("sonnet", "claude-sonnet-5-5"),
        ("haiku", "claude-haiku-5-5")
    ]

    /// "us.anthropic.claude-opus-4-5@20251101[1m]" -> "claude-opus-4-5-20251101"
    public static func normalize(_ model: String) -> String {
        var m = model.lowercased()
        if let bracket = m.firstIndex(of: "[") { m = String(m[..<bracket]) }
        if let r = m.range(of: "claude") { m = String(m[r.lowerBound...]) }
        m = m.replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "@", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        return m.trimmingCharacters(in: .whitespaces)
    }

    public func resolveKey(_ model: String) -> String? {
        let n = Self.normalize(model)
        for key in sortedKeys where n == key || n.hasPrefix(key + "-") {
            return key
        }
        for (family, key) in Self.familyFallback where n.contains(family) && prices[key] != nil {
            return key
        }
        return nil
    }

    private func price(for r: UsageRecord) -> ModelPrice? {
        guard let key = resolveKey(r.model), var p = prices[key] else { return nil }
        if let tier = tiers[key], r.promptTokens > tier.promptThreshold { p = tier.price }
        return p
    }

    /// Dollars saved by reading prompt tokens from cache instead of sending them as fresh input.
    public func cacheSavings(_ r: UsageRecord) -> Double {
        guard let p = price(for: r) else { return 0 }
        return Double(r.cacheRead) * max(0, p.input - p.cacheRead) / 1_000_000
    }

    public func cost(_ r: UsageRecord) -> Double {
        guard let p = price(for: r) else { return 0 }
        let sum = Double(r.input) * p.input
            + Double(r.cacheWrite5m) * p.cacheWrite5m
            + Double(r.cacheWrite1h) * p.cacheWrite1h
            + Double(r.cacheRead) * p.cacheRead
            + Double(r.output) * p.output
        return sum / 1_000_000
    }

    // MARK: - pricing.json

    struct PricingFile: Codable {
        var note: String?
        var models: [String: ModelPrice]

        enum CodingKeys: String, CodingKey {
            case note = "_note"
            case models
        }
    }

    public static func load(from url: URL?) -> PricingTable {
        var prices = defaultPrices
        if let url, let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(PricingFile.self, from: data) {
            for (k, v) in file.models { prices[normalize(k)] = v }
        }
        return PricingTable(prices: prices)
    }

    public static func writeDefaults(to url: URL) throws {
        let file = PricingFile(
            note: "USD per million tokens. Edit any model, or add a new one by its model-id prefix, then press Reload prices in Credo Settings. Keys match by prefix (claude-opus-4-5 covers claude-opus-4-5-20251101).",
            models: defaultPrices)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: url, options: .atomic)
    }
}

public enum ModelNames {
    /// "claude-opus-4-5-20251101" -> "Opus 4.5", "claude-3-5-sonnet-20241022" -> "Sonnet 3.5"
    public static func pretty(_ model: String) -> String {
        let n = PricingTable.normalize(model)
        guard n.hasPrefix("claude") else { return model.isEmpty ? "Unknown" : model }
        var parts = n.split(separator: "-").map(String.init)
        if !parts.isEmpty { parts.removeFirst() }
        parts = parts.filter { part in
            let isDate = part.count >= 8 && part.allSatisfy { $0.isNumber }
            return !isDate && !part.hasPrefix("v1") && part != "latest"
        }
        let families = ["opus", "sonnet", "haiku", "fable", "mythos"]
        guard let family = parts.first(where: { families.contains($0) }) else { return model }
        let numbers = parts.filter { !$0.isEmpty && $0.allSatisfy { $0.isNumber } }
        let version = numbers.prefix(2).joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }
}
