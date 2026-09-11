import XCTest
@testable import ContextCacheKit

final class MissDiagnoserTests: XCTestCase {
    private var base: ContextSnapshot {
        ContextSnapshot(
            tools: [ToolDefinition(name: "Read", tokens: 100), ToolDefinition(name: "Bash", tokens: 200)],
            system: [SystemSegment(name: "CLAUDE.md", tokens: 1_000)],
            messages: [Message(role: .user, tokens: 50)])
    }

    private func diagnose(_ current: ContextSnapshot, elapsed: TimeInterval = 30) -> MissCause {
        MissDiagnoser.diagnose(previous: base, current: current, elapsed: elapsed, ttl: .fiveMinutes)
    }

    func testColdStartIsNotAMiss() {
        XCTAssertEqual(MissDiagnoser.diagnose(previous: nil, current: base, elapsed: 0, ttl: .fiveMinutes), .none)
    }

    func testUnchangedAndOnTimeIsAHit() {
        var next = base
        next.messages.append(Message(role: .user, tokens: 10))
        XCTAssertEqual(diagnose(next), .none)
    }

    func testIdlePastTTL() {
        XCTAssertEqual(diagnose(base, elapsed: 301), .idlePastTTL(idleSeconds: 301))
        XCTAssertEqual(diagnose(base, elapsed: 300), .none, "exactly one TTL is still inside the window")
    }

    func testToolSetChanges() {
        var added = base
        added.tools.append(ToolDefinition(name: "Grep", tokens: 50))
        XCTAssertEqual(diagnose(added), .toolSetChanged(added: ["Grep"], removed: [], changed: []))

        var removed = base
        removed.tools.removeLast()
        XCTAssertEqual(diagnose(removed), .toolSetChanged(added: [], removed: ["Bash"], changed: []))

        var changed = base
        changed.tools[1].schemaVersion = 2
        XCTAssertEqual(diagnose(changed), .toolSetChanged(added: [], removed: [], changed: ["Bash"]))
    }

    func testToolOrderChange() {
        var reordered = base
        reordered.tools.reverse()
        XCTAssertEqual(diagnose(reordered), .toolOrderChanged)
    }

    func testSystemSegmentChangeNamesTheSegment() {
        var edited = base
        edited.system[0].version = 2
        XCTAssertEqual(diagnose(edited), .systemSegmentChanged(segments: ["CLAUDE.md"]))

        var loaded = base
        loaded.system.append(SystemSegment(name: "skill:networking", tokens: 400))
        XCTAssertEqual(diagnose(loaded), .systemSegmentChanged(segments: ["skill:networking"]))
    }

    func testMessageRewriteReportsTheIndex() {
        var rewritten = base
        rewritten.messages[0].revision = 1
        XCTAssertEqual(diagnose(rewritten), .messagePrefixRewritten(atIndex: 0))
    }

    func testToolChangeOutranksEverythingElse() {
        var all = base
        all.tools[0].schemaVersion = 2
        all.system[0].version = 2
        all.messages[0].revision = 1
        XCTAssertEqual(diagnose(all, elapsed: 900), .toolSetChanged(added: [], removed: [], changed: ["Read"]))
    }

    func testDescriptionsAreReadable() {
        XCTAssertEqual(MissCause.toolOrderChanged.description, "tool order changed")
        XCTAssertEqual(MissCause.idlePastTTL(idleSeconds: 1_320).description, "idle 1320s past TTL")
        XCTAssertEqual(MissCause.toolSetChanged(added: [], removed: [], changed: ["Bash"]).category, "tool set changed")
    }
}
