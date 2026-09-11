import Foundation

/// Where a skill's text lands when it is loaded mid-session.
public enum SkillPlacement: Hashable, Sendable {
    /// Spliced into the top-level system prompt. Changes the system hash and everything after it.
    case systemPrompt
    /// Appended to the conversation as a system-role message. Leaves every earlier block untouched.
    case appendedMessage
}

/// One thing that happens to the request between turns.
public enum SessionEvent: Hashable, Sendable {
    /// The user sends a message `after` seconds after the previous request. This is what triggers a request.
    case user(tokens: Int, after: TimeInterval)
    /// The model replies (including tool-call round trips rolled up), appended to the transcript.
    case assistant(tokens: Int)
    /// A skill is loaded, placed either in the system prompt or as an appended message.
    case loadSkill(name: String, tokens: Int, placement: SkillPlacement)
    /// A system segment (CLAUDE.md, memory, a skill) is edited in place.
    case editSegment(name: String, newTokens: Int)
    /// An MCP server reconnects and its tools are re-registered at the end of the tool list.
    case reconnectServer(prefix: String)
    /// A tool definition is re-rendered with a different schema (or added if absent).
    case rerenderTool(name: String, tokens: Int)
    /// The harness rewrites an earlier message block in place.
    case rewriteMessage(index: Int)
}

public struct SessionScript: Hashable, Sendable {
    public var name: String
    public var initial: ContextSnapshot
    public var events: [SessionEvent]
    public var ttl: CacheTTL

    public init(name: String, initial: ContextSnapshot, events: [SessionEvent], ttl: CacheTTL = .fiveMinutes) {
        self.name = name
        self.initial = initial
        self.events = events
        self.ttl = ttl
    }
}

/// One request's line in the ledger.
public struct TurnRecord: Hashable, Sendable, Identifiable {
    public var id: Int { turn }
    public var turn: Int
    public var elapsedSinceStart: TimeInterval
    public var result: CacheResult
    public var cause: MissCause
    /// Tokens that were new this turn and had to be sent regardless.
    public var newTokens: Int
    /// Tokens the cache already held last turn and had to be written again.
    public var tokensRecached: Int
    public var cost: Double
    /// What the turn would have cost had the whole previous prefix been served from cache.
    public var idealCost: Double

    public var isHit: Bool { if case .none = cause { return true } else { return false } }
    public var overspend: Double { max(0, cost - idealCost) }
}

/// Aggregate over a session, plus the per-cause breakdown a lead would rank fixes by.
public struct SessionReport: Hashable, Sendable {
    public struct CauseLine: Hashable, Sendable, Identifiable {
        public var id: String { category }
        public var category: String
        public var turns: Int
        public var tokensRecached: Int
        public var overspend: Double
    }

    public var scriptName: String
    public var ttl: CacheTTL
    public var turns: [TurnRecord]
    public var sharedPrefixTokens: Int

    public var requestCount: Int { turns.count }
    public var totalInputTokens: Int { turns.reduce(0) { $0 + $1.result.totalTokens } }
    public var cachedTokens: Int { turns.reduce(0) { $0 + $1.result.cachedTokens } }
    /// Cached input tokens over all input tokens, the figure `/cost` reports as the hit ratio.
    public var hitRatio: Double { totalInputTokens == 0 ? 0 : Double(cachedTokens) / Double(totalInputTokens) }
    public var missCount: Int { turns.filter { !$0.isHit }.count }
    public var tokensRecached: Int { turns.reduce(0) { $0 + $1.tokensRecached } }
    public var cost: Double { turns.reduce(0) { $0 + $1.cost } }
    public var idealCost: Double { turns.reduce(0) { $0 + $1.idealCost } }
    public var overspend: Double { max(0, cost - idealCost) }

    /// Causes ranked by dollars over ideal, largest first. Fix the top line first.
    public var causes: [CauseLine] {
        var bucket: [String: CauseLine] = [:]
        for turn in turns where !turn.isHit {
            let key = turn.cause.category
            var line = bucket[key] ?? CauseLine(category: key, turns: 0, tokensRecached: 0, overspend: 0)
            line.turns += 1
            line.tokensRecached += turn.tokensRecached
            line.overspend += turn.overspend
            bucket[key] = line
        }
        return bucket.values.sorted { ($0.overspend, $0.category) > ($1.overspend, $1.category) }
    }
}

/// Replays a script through a `PromptCache` and prices every request.
public struct SessionSimulator: Sendable {
    public var pricing: Pricing

    public init(pricing: Pricing = .fable51) {
        self.pricing = pricing
    }

    public func run(_ script: SessionScript) -> SessionReport {
        var cache = PromptCache(ttl: script.ttl)
        var snapshot = script.initial
        var previous: ContextSnapshot?
        var clock: TimeInterval = 0
        var lastRequest: TimeInterval = 0
        var turns: [TurnRecord] = []
        var turnNumber = 0

        for event in script.events {
            switch event {
            case let .user(tokens, after):
                snapshot.messages.append(Message(role: .user, tokens: tokens))
                clock += after
                turnNumber += 1
                let elapsed = clock - lastRequest
                let result = cache.serve(snapshot, at: Date(timeIntervalSinceReferenceDate: clock))
                let cause = MissDiagnoser.diagnose(previous: previous, current: snapshot, elapsed: elapsed, ttl: script.ttl)
                let newTokens = max(0, snapshot.totalTokens - (previous?.totalTokens ?? 0))
                let recached = previous == nil ? 0 : max(0, result.uncachedTokens - newTokens)
                let cost = result.cost(pricing: pricing, ttl: script.ttl)
                let ideal = previous == nil ? cost : CacheResult(cachedTokens: snapshot.totalTokens - newTokens,
                                                                 uncachedTokens: newTokens,
                                                                 matchedBlockIndex: nil, matchedLevel: nil)
                    .cost(pricing: pricing, ttl: script.ttl)
                let record = TurnRecord(turn: turnNumber, elapsedSinceStart: clock, result: result,
                                        cause: cause, newTokens: newTokens,
                                        tokensRecached: recached, cost: cost, idealCost: ideal)
                turns.append(record)
                previous = snapshot
                lastRequest = clock

            case let .assistant(tokens):
                snapshot.messages.append(Message(role: .assistant, tokens: tokens))

            case let .loadSkill(name, tokens, placement):
                switch placement {
                case .systemPrompt:
                    snapshot.system.append(SystemSegment(name: name, tokens: tokens))
                case .appendedMessage:
                    snapshot.messages.append(Message(role: .system, tokens: tokens))
                }

            case let .editSegment(name, newTokens):
                if let index = snapshot.system.firstIndex(where: { $0.name == name }) {
                    snapshot.system[index].tokens = newTokens
                    snapshot.system[index].version += 1
                }

            case let .reconnectServer(prefix):
                let moved = snapshot.tools.filter { $0.name.hasPrefix(prefix) }
                snapshot.tools.removeAll { $0.name.hasPrefix(prefix) }
                snapshot.tools.append(contentsOf: moved)

            case let .rerenderTool(name, tokens):
                if let index = snapshot.tools.firstIndex(where: { $0.name == name }) {
                    snapshot.tools[index].tokens = tokens
                    snapshot.tools[index].schemaVersion += 1
                } else {
                    snapshot.tools.append(ToolDefinition(name: name, tokens: tokens))
                }

            case let .rewriteMessage(index):
                if snapshot.messages.indices.contains(index) {
                    snapshot.messages[index].revision += 1
                }
            }
        }

        return SessionReport(scriptName: script.name, ttl: script.ttl, turns: turns,
                             sharedPrefixTokens: script.initial.sharedPrefixTokens)
    }
}
