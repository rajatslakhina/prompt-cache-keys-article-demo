import Foundation

/// Per-million-token prices. Defaults mirror the published Claude Fable 5.1 card:
/// $10 base input, $12.50 five-minute write, $20 one-hour write, $0.25 cache read.
public struct Pricing: Hashable, Sendable {
    public var inputPerMillion: Double
    public var write5mPerMillion: Double
    public var write1hPerMillion: Double
    public var readPerMillion: Double

    public init(inputPerMillion: Double, write5mPerMillion: Double, write1hPerMillion: Double, readPerMillion: Double) {
        self.inputPerMillion = inputPerMillion
        self.write5mPerMillion = write5mPerMillion
        self.write1hPerMillion = write1hPerMillion
        self.readPerMillion = readPerMillion
    }

    public static let fable51 = Pricing(inputPerMillion: 10, write5mPerMillion: 12.5, write1hPerMillion: 20, readPerMillion: 0.25)
    public static let sonnet5 = Pricing(inputPerMillion: 2, write5mPerMillion: 2.5, write1hPerMillion: 4, readPerMillion: 0.20)

    public func writePrice(for ttl: CacheTTL) -> Double {
        switch ttl {
        case .fiveMinutes: return write5mPerMillion
        case .oneHour: return write1hPerMillion
        }
    }
}

public enum CacheTTL: Hashable, Sendable {
    case fiveMinutes, oneHour

    public var seconds: TimeInterval {
        switch self {
        case .fiveMinutes: return 300
        case .oneHour: return 3600
        }
    }
}

/// What one request cost the cache: how much of the prefix was served from it and how much was written fresh.
public struct CacheResult: Hashable, Sendable {
    public var cachedTokens: Int
    public var uncachedTokens: Int
    /// Index into `blocks()` of the deepest block that matched, or nil for a cold request.
    public var matchedBlockIndex: Int?
    /// The prefix level of the deepest match. `.messages` means the shared prefix was fully served.
    public var matchedLevel: PrefixLevel?

    public var totalTokens: Int { cachedTokens + uncachedTokens }

    public func cost(pricing: Pricing, ttl: CacheTTL) -> Double {
        Double(cachedTokens) / 1_000_000 * pricing.readPerMillion
            + Double(uncachedTokens) / 1_000_000 * pricing.writePrice(for: ttl)
    }
}

/// A model of the API's prefix cache: entries keyed by prefix hash, each expiring one TTL after its last use,
/// looked up by walking back from each breakpoint through at most `lookback` earlier blocks.
public struct PromptCache: Sendable {
    public var ttl: CacheTTL
    public var lookback: Int
    private var expiry: [UInt64: Date] = [:]

    public init(ttl: CacheTTL = .fiveMinutes, lookback: Int = 20) {
        self.ttl = ttl
        self.lookback = max(1, lookback)
    }

    public var liveEntryCount: Int { expiry.count }

    /// Serves one request at `now`: finds the longest live cached prefix, then writes entries at every breakpoint.
    /// A hit refreshes the entry's TTL, as the API does, at no charge.
    @discardableResult
    public mutating func serve(_ snapshot: ContextSnapshot, at now: Date) -> CacheResult {
        let blocks = snapshot.blocks()
        expiry = expiry.filter { $0.value > now }

        var bestIndex: Int?
        let breakpoints = blocks.indices.filter { blocks[$0].isBreakpoint }.reversed()
        search: for bp in breakpoints {
            let floor = max(0, bp - (lookback - 1))
            for index in stride(from: bp, through: floor, by: -1) {
                if expiry[blocks[index].prefixHash] != nil {
                    bestIndex = index
                    break search
                }
            }
        }

        var cached = 0
        var uncached = 0
        for (index, block) in blocks.enumerated() {
            if let best = bestIndex, index <= best { cached += block.tokens } else { uncached += block.tokens }
        }

        let newExpiry = now.addingTimeInterval(ttl.seconds)
        for index in blocks.indices where blocks[index].isBreakpoint {
            expiry[blocks[index].prefixHash] = newExpiry
        }
        if let best = bestIndex {
            // Reading through an entry refreshes it too.
            expiry[blocks[best].prefixHash] = newExpiry
        }

        return CacheResult(cachedTokens: cached, uncachedTokens: uncached,
                           matchedBlockIndex: bestIndex, matchedLevel: bestIndex.map { blocks[$0].level })
    }
}
