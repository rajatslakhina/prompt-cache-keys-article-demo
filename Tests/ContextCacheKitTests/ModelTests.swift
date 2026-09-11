import XCTest
@testable import ContextCacheKit

final class ModelTests: XCTestCase {
    private func snapshot(messages: Int = 2) -> ContextSnapshot {
        ContextSnapshot(
            tools: [ToolDefinition(name: "Read", tokens: 100), ToolDefinition(name: "Bash", tokens: 200)],
            system: [SystemSegment(name: "CLAUDE.md", tokens: 1_000), SystemSegment(name: "memory", tokens: 300)],
            messages: (0..<messages).map { Message(role: $0 % 2 == 0 ? .user : .assistant, tokens: 50) })
    }

    func testBlocksLayoutAndBreakpoints() {
        let blocks = snapshot().blocks()
        XCTAssertEqual(blocks.count, 1 + 2 + 2)
        XCTAssertEqual(blocks.map(\.level), [.tools, .system, .system, .messages, .messages])
        XCTAssertEqual(blocks.map(\.isBreakpoint), [true, false, true, false, true])
        XCTAssertEqual(blocks[0].tokens, 300)
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.tokens }, snapshot().totalTokens)
        XCTAssertEqual(snapshot().sharedPrefixTokens, 1_600)
    }

    func testEmptySnapshotHasNoBlocks() {
        let empty = ContextSnapshot(tools: [], system: [], messages: [])
        XCTAssertTrue(empty.blocks().isEmpty)
        var cache = PromptCache()
        let result = cache.serve(empty, at: Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(result.totalTokens, 0)
        XCTAssertNil(result.matchedBlockIndex)
    }

    func testPrefixHashIsDeterministicAndOrderSensitive() {
        XCTAssertEqual(snapshot().blocks().map(\.prefixHash), snapshot().blocks().map(\.prefixHash))
        var reordered = snapshot()
        reordered.tools.reverse()
        XCTAssertNotEqual(snapshot().blocks()[0].prefixHash, reordered.blocks()[0].prefixHash)

        var a = PrefixHasher(), b = PrefixHasher()
        a.feed("ab"); a.feed("c")
        b.feed("a"); b.feed("bc")
        XCTAssertNotEqual(a.value, b.value, "block boundaries must be part of the hash")
    }

    func testEditingALaterBlockKeepsEarlierHashes() {
        var edited = snapshot()
        edited.system[1].version += 1
        let before = snapshot().blocks(), after = edited.blocks()
        XCTAssertEqual(before[0].prefixHash, after[0].prefixHash)
        XCTAssertEqual(before[1].prefixHash, after[1].prefixHash)
        XCTAssertNotEqual(before[2].prefixHash, after[2].prefixHash)
    }
}
