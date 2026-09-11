import Foundation

/// A realistic afternoon on an iOS monorepo: 16 harness tools, 17 MCP tools from three servers,
/// a ~200-line CLAUDE.md, memory, two skills loaded at start, and 40 user turns.
/// `baseline` is how most sessions actually run. `stabilized` is the same afternoon with the
/// prefix treated as a cache key.
public enum Fixture {
    public static let harnessTools: [ToolDefinition] = [
        ("Read", 640), ("Edit", 980), ("Write", 520), ("Bash", 1_450), ("Glob", 410), ("Grep", 1_120),
        ("Agent", 1_380), ("WebFetch", 560), ("WebSearch", 470), ("TodoWrite", 610), ("NotebookEdit", 690),
        ("AskUserQuestion", 720), ("KillShell", 210), ("BashOutput", 330), ("SlashCommand", 380), ("Skill", 540),
    ].map { ToolDefinition(name: $0.0, tokens: $0.1) }

    public static let mcpTools: [ToolDefinition] = [
        ("xcode.build", 540), ("xcode.test", 610), ("xcode.simulators", 380), ("xcode.previews", 450), ("xcode.docs", 320),
        ("github.create_pr", 720), ("github.get_pr", 480), ("github.list_prs", 460), ("github.comment", 390),
        ("github.get_file", 430), ("github.search_code", 560), ("github.checks", 510), ("github.merge", 470),
        ("linear.issue", 520), ("linear.search", 480), ("linear.update", 450), ("linear.comment", 360),
    ].map { ToolDefinition(name: $0.0, tokens: $0.1) }

    public static let systemPrompt: [SystemSegment] = [
        SystemSegment(name: "harness preamble", tokens: 3_400),
        SystemSegment(name: "CLAUDE.md", tokens: 4_200),
        SystemSegment(name: "memory", tokens: 1_100),
        SystemSegment(name: "skill:swiftui-specialist", tokens: 6_100),
        SystemSegment(name: "skill:monorepo-conventions", tokens: 2_900),
    ]

    public static var initialSnapshot: ContextSnapshot {
        ContextSnapshot(tools: harnessTools + mcpTools, system: systemPrompt, messages: [])
    }

    /// Forty user turns, one every ~45 s, each answered with ~600 tokens of reply and tool results.
    /// `extras` inserts events *before* the numbered user turn;
    /// `idleBefore` overrides the gap (seconds) before a numbered turn; every other gap is 45 s.
    static func conversation(turns: Int = 40, extras: [Int: [SessionEvent]],
                             idleBefore: [Int: TimeInterval]) -> [SessionEvent] {
        var events: [SessionEvent] = []
        for turn in 1...turns {
            events.append(contentsOf: extras[turn] ?? [])
            let after = idleBefore[turn] ?? 45
            let userTokens = 120 + (turn * 37) % 90
            let replyTokens = 520 + (turn * 53) % 220
            events.append(.user(tokens: userTokens, after: after))
            events.append(.assistant(tokens: replyTokens))
        }
        return events
    }

    /// The session as most teams run it. Six things happen that each break the prefix.
    public static var baseline: SessionScript {
        SessionScript(name: "Baseline", initial: initialSnapshot, events: conversation(extras: [
            // Agent-team teammate re-announces its first-turn tools on turn two, rewriting the first message.
            2: [.rewriteMessage(index: 0)],
            // A networking skill is loaded on demand, spliced into the system prompt.
            8: [.loadSkill(name: "skill:networking-layer", tokens: 5_200, placement: .systemPrompt)],
            // The GitHub MCP server reconnects and re-registers its eight tools at the end of the list.
            14: [.reconnectServer(prefix: "github.")],
            // Someone merges a CLAUDE.md change mid-afternoon and the harness picks it up.
            26: [.editSegment(name: "CLAUDE.md", newTokens: 4_350)],
            // A testing skill is loaded, also into the system prompt.
            33: [.loadSkill(name: "skill:testing-conventions", tokens: 4_100, placement: .systemPrompt)],
            // A reconnecting client re-renders the Bash tool definition with a slightly different schema.
            37: [.rerenderTool(name: "Bash", tokens: 1_480)],
        ], idleBefore: [
            // Lunch: 22 minutes idle before turn 20, well past a five-minute TTL.
            20: 1_320,
        ]))
    }

    /// The same afternoon with the prefix engineered as a cache key: no rewrite bug, skills appended as
    /// messages, tool order pinned, CLAUDE.md changes held until the next session, tool schemas frozen.
    /// The lunch break is untouched, because a TTL is a policy choice rather than a prefix bug.
    public static var stabilized: SessionScript {
        SessionScript(name: "Stabilized", initial: initialSnapshot, events: conversation(extras: [
            8: [.loadSkill(name: "skill:networking-layer", tokens: 5_200, placement: .appendedMessage)],
            33: [.loadSkill(name: "skill:testing-conventions", tokens: 4_100, placement: .appendedMessage)],
        ], idleBefore: [20: 1_320]))
    }

    /// Stabilized, with the one-hour TTL that survives lunch, at twice the write price.
    public static var stabilizedOneHour: SessionScript {
        var script = stabilized
        script.name = "Stabilized · 1h TTL"
        script.ttl = .oneHour
        return script
    }
}
