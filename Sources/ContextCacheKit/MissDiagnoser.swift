import Foundation

/// Why a turn failed to reuse the previous turn's prefix. Mirrors the causes a harness can report,
/// ordered by how much of the prefix each one throws away.
public enum MissCause: Hashable, Sendable, CustomStringConvertible {
    /// A tool was added, removed, or its schema changed. Invalidates tools, system and messages.
    case toolSetChanged(added: [String], removed: [String], changed: [String])
    /// Same tools, different order. Same blast radius as a schema change.
    case toolOrderChanged
    /// A system segment was edited, added or removed. Invalidates system and messages, keeps tools.
    case systemSegmentChanged(segments: [String])
    /// An earlier message block was rewritten. Invalidates from that block on.
    case messagePrefixRewritten(atIndex: Int)
    /// The previous entry expired before this request arrived.
    case idlePastTTL(idleSeconds: TimeInterval)
    /// Nothing changed and the request was on time: the prefix was served from cache.
    case none

    public var description: String {
        switch self {
        case let .toolSetChanged(added, removed, changed):
            var parts: [String] = []
            if !added.isEmpty { parts.append("added \(added.joined(separator: ", "))") }
            if !removed.isEmpty { parts.append("removed \(removed.joined(separator: ", "))") }
            if !changed.isEmpty { parts.append("changed \(changed.joined(separator: ", "))") }
            return "tool set changed (\(parts.joined(separator: "; ")))"
        case .toolOrderChanged:
            return "tool order changed"
        case let .systemSegmentChanged(segments):
            return "system prompt changed (\(segments.joined(separator: ", ")))"
        case let .messagePrefixRewritten(index):
            return "message #\(index) rewritten"
        case let .idlePastTTL(seconds):
            return "idle \(Int(seconds))s past TTL"
        case .none:
            return "hit"
        }
    }

    /// A short, stable label for grouping in reports.
    public var category: String {
        switch self {
        case .toolSetChanged: return "tool set changed"
        case .toolOrderChanged: return "tool order changed"
        case .systemSegmentChanged: return "system prompt changed"
        case .messagePrefixRewritten: return "message prefix rewritten"
        case .idlePastTTL: return "idle past TTL"
        case .none: return "hit"
        }
    }
}

/// Compares two consecutive requests and names the first cause, in hash order, that would break the prefix.
public enum MissDiagnoser {
    public static func diagnose(previous: ContextSnapshot?, current: ContextSnapshot,
                                elapsed: TimeInterval, ttl: CacheTTL) -> MissCause {
        // The first request of a session has nothing to reuse; it is a cold start, not a miss.
        guard let previous else { return .none }

        let prevNames = previous.tools.map(\.name)
        let curNames = current.tools.map(\.name)
        let prevSet = Set(prevNames), curSet = Set(curNames)
        let added = curNames.filter { !prevSet.contains($0) }
        let removed = prevNames.filter { !curSet.contains($0) }
        let prevByName = Dictionary(previous.tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let changed = current.tools.filter { tool in
            guard let old = prevByName[tool.name] else { return false }
            return old.schemaVersion != tool.schemaVersion || old.tokens != tool.tokens
        }.map(\.name)
        if !added.isEmpty || !removed.isEmpty || !changed.isEmpty {
            return .toolSetChanged(added: added, removed: removed, changed: changed)
        }
        if prevNames != curNames {
            return .toolOrderChanged
        }

        if previous.system != current.system {
            let prevSeg = Dictionary(previous.system.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            let curSeg = Dictionary(current.system.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            var names: [String] = []
            for segment in current.system where prevSeg[segment.name] != segment { names.append(segment.name) }
            for segment in previous.system where curSeg[segment.name] == nil { names.append(segment.name) }
            if names.isEmpty { names = ["order"] }
            return .systemSegmentChanged(segments: names)
        }

        let shared = min(previous.messages.count, current.messages.count)
        for index in 0..<shared where previous.messages[index] != current.messages[index] {
            return .messagePrefixRewritten(atIndex: index)
        }

        if elapsed > ttl.seconds {
            return .idlePastTTL(idleSeconds: elapsed)
        }
        return .none
    }
}
