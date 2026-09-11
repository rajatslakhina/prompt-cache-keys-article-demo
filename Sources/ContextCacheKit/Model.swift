import Foundation

/// One tool definition as the API sees it: its name and the tokens its JSON schema costs.
public struct ToolDefinition: Hashable, Sendable {
    public var name: String
    public var tokens: Int
    /// Bumped when the schema or description text changes.
    public var schemaVersion: Int

    public init(name: String, tokens: Int, schemaVersion: Int = 1) {
        self.name = name
        self.tokens = tokens
        self.schemaVersion = schemaVersion
    }
}

/// One segment of the system prompt: CLAUDE.md, a loaded skill, a memory file, the harness preamble.
public struct SystemSegment: Hashable, Sendable {
    public var name: String
    public var tokens: Int
    /// Bumped whenever the segment's text changes.
    public var version: Int

    public init(name: String, tokens: Int, version: Int = 1) {
        self.name = name
        self.tokens = tokens
        self.version = version
    }
}

public enum Role: String, Hashable, Sendable {
    case user, assistant, tool, system
}

/// One block in the messages array. `revision` changes when the harness rewrites an earlier block.
public struct Message: Hashable, Sendable {
    public var role: Role
    public var tokens: Int
    public var revision: Int

    public init(role: Role, tokens: Int, revision: Int = 0) {
        self.role = role
        self.tokens = tokens
        self.revision = revision
    }
}

/// The three levels of the cached prefix, in the order the API hashes them.
public enum PrefixLevel: String, CaseIterable, Sendable {
    case tools, system, messages
}

/// A block boundary in the assembled request, with the cumulative hash of everything before and including it.
public struct Block: Hashable, Sendable {
    public var level: PrefixLevel
    public var label: String
    public var tokens: Int
    /// Hash of the whole prefix ending at this block. Two requests share a cache entry only if these match.
    public var prefixHash: UInt64
    /// Whether the harness placed an explicit cache breakpoint on this block.
    public var isBreakpoint: Bool
}

/// The full request as assembled by the harness for one turn.
public struct ContextSnapshot: Hashable, Sendable {
    public var tools: [ToolDefinition]
    public var system: [SystemSegment]
    public var messages: [Message]

    public init(tools: [ToolDefinition], system: [SystemSegment], messages: [Message]) {
        self.tools = tools
        self.system = system
        self.messages = messages
    }

    public var totalTokens: Int {
        tools.reduce(0) { $0 + $1.tokens }
            + system.reduce(0) { $0 + $1.tokens }
            + messages.reduce(0) { $0 + $1.tokens }
    }

    /// Tokens in the shared prefix (tools + system) that every turn re-sends.
    public var sharedPrefixTokens: Int {
        tools.reduce(0) { $0 + $1.tokens } + system.reduce(0) { $0 + $1.tokens }
    }

    /// Lays the request out as the API hashes it: one block for the tool array, one per system
    /// segment, one per message. Explicit breakpoints sit after the tools and after the system
    /// prompt; the automatic breakpoint sits on the last message.
    public func blocks() -> [Block] {
        var out: [Block] = []
        var hasher = PrefixHasher()

        var toolTokens = 0
        for tool in tools {
            hasher.feed("tool:\(tool.name):v\(tool.schemaVersion):\(tool.tokens)")
            toolTokens += tool.tokens
        }
        if !tools.isEmpty {
            out.append(Block(level: .tools, label: "tools[\(tools.count)]", tokens: toolTokens,
                             prefixHash: hasher.value, isBreakpoint: true))
        }

        for (index, segment) in system.enumerated() {
            hasher.feed("system:\(segment.name):v\(segment.version):\(segment.tokens)")
            let last = index == system.count - 1
            out.append(Block(level: .system, label: segment.name, tokens: segment.tokens,
                             prefixHash: hasher.value, isBreakpoint: last))
        }

        for (index, message) in messages.enumerated() {
            hasher.feed("msg:\(index):\(message.role.rawValue):r\(message.revision):\(message.tokens)")
            let last = index == messages.count - 1
            out.append(Block(level: .messages, label: "\(message.role.rawValue)#\(index)", tokens: message.tokens,
                             prefixHash: hasher.value, isBreakpoint: last))
        }
        return out
    }
}

/// Deterministic 64-bit FNV-1a over the block descriptors, so the same prefix hashes the same on every run and platform.
public struct PrefixHasher: Sendable {
    public private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    public init() {}

    public mutating func feed(_ text: String) {
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        // Block separator so "ab"+"c" never equals "a"+"bc".
        value ^= 0x1f
        value = value &* 0x0000_0100_0000_01b3
    }
}
