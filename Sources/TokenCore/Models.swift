import Foundation

/// Which AI provider a tool belongs to. Credo reads Anthropic (Claude) logs today; OpenAI and
/// Google tools are planned.
public enum Provider: String, CaseIterable, Sendable, Identifiable {
    case all, anthropic, openai, google

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: return "All"
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .google: return "Google"
        }
    }

    /// Whether Credo can read this provider's local logs yet.
    public var isSupported: Bool { self == .all || self == .anthropic }

    public var plannedTools: String {
        switch self {
        case .openai: return "Codex CLI and ChatGPT desktop"
        case .google: return "Gemini CLI"
        default: return ""
        }
    }
}

/// Which tool produced a usage record.
public enum UsageSource: String, CaseIterable, Sendable, Identifiable {
    /// Claude Code in a terminal (entrypoint "cli").
    case claudeCodeCLI = "cli"
    /// Claude Code inside VS Code / Cursor (entrypoint "claude-vscode").
    case vscode = "vscode"
    /// Claude Code sessions started from Claude Desktop's Code tab (entrypoint "claude-desktop").
    case desktopCode = "desktop-code"
    /// Claude Desktop agent sessions (local-agent-mode-sessions).
    case desktopAgent = "desktop-agent"
    case agentSDK = "sdk"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCodeCLI: return "Claude Code · Terminal"
        case .vscode: return "Claude Code · VS Code"
        case .desktopCode: return "Claude Desktop · Code tab"
        case .desktopAgent: return "Claude Desktop · Agent sessions"
        case .agentSDK: return "Agent SDK / other"
        }
    }

    public var shortName: String {
        switch self {
        case .claudeCodeCLI: return "Terminal"
        case .vscode: return "VS Code"
        case .desktopCode: return "Code tab"
        case .desktopAgent: return "Agent"
        case .agentSDK: return "SDK"
        }
    }

    /// Everything except agent sessions is a Claude Code session in ~/.claude/projects —
    /// the same set Claude Code's own Stats panel covers.
    public var isClaudeCode: Bool { self != .desktopAgent }

    /// Every tool Credo reads today is a Claude (Anthropic) tool.
    public var provider: Provider { .anthropic }

    /// Sessions that ran inside Claude Desktop (Code tab or agent sessions).
    public var isDesktop: Bool { self == .desktopCode || self == .desktopAgent }

    /// SF Symbol used in widgets and breakdowns.
    public var symbol: String {
        switch self {
        case .claudeCodeCLI: return "terminal"
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .desktopCode: return "macwindow"
        case .desktopAgent: return "sparkles"
        case .agentSDK: return "shippingbox"
        }
    }
}

/// One model API call (one assistant message) found in a local log.
public struct UsageRecord: Sendable {
    public var key: String
    public var timestamp: Date
    public var source: UsageSource
    public var model: String
    public var project: String
    public var sessionId: String
    public var input: Int
    public var output: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int
    public var cacheRead: Int
    public var cost: Double = 0
    /// False when the log line had no timestamp and the file's modification time was used instead.
    /// Such records still count in totals but never start or extend the 5-hour window.
    public var timestampKnown: Bool = true
    /// What prompt caching saved versus paying the full input price for the cache-read tokens.
    public var saved: Double = 0

    public var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    /// Everything sent to the model (used for long-context price tiers).
    public var promptTokens: Int { input + cacheWrite + cacheRead }
    public var total: Int { input + output + cacheWrite + cacheRead }
}
