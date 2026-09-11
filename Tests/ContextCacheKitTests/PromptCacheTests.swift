import XCTest
@testable import ContextCacheKit

final class PromptCacheTests: XCTestCase {
    private func snapshot(messages: Int = 2, toolVersion: Int = 1, claudeVersion: Int = 1) -> ContextSnapshot {
        ContextSnapshot(
            tools: [ToolDefinition(name: "Read", tokens: 100), ToolDefinition(name: "Bash", tokens: 200, schemaVersion: toolVersion)],
            system: [SystemSegment(name: "CLAUDE.md", tokens: 1_000, version: claudeVersion), SystemSegment(name: "memory", tokens: 300)],
            messages: (0..<messages).map { Message(role: $0 % 2 == 0 ? .user : .assistant, tokens: 50) })
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    func testColdThenWarm() {
        var cache = PromptCache()
        let cold = cache.serve(snapshot(), at: at(0))
        XCTAssertEqual(cold.cachedTokens, 0)
        XCTAssertEqual(cold.uncachedTokens, 1_700)

        let warm = cache.serve(snapshot(messages: 3), at: at(30))
        XCTAssertEqual(warm.cachedTokens, 1_700, "everything up to the previous last message is served from cache")
        XCTAssertEqual(warm.uncachedTokens, 50)
        XCTAssertEqual(warm.matchedLevel, .messages)
    }

    func testEntryExpiresAfterTTLAndHitsRefreshIt() {
        var cache = PromptCache(ttl: .fiveMinutes)
        cache.serve(snapshot(), at: at(0))
        XCTAssertEqual(cache.serve(snapshot(messages: 3), at: at(299)).cachedTokens, 1_700)
        // The hit at t=299 refreshed the entry, so t=598 is still within one TTL of the last use.
        XCTAssertEqual(cache.serve(snapshot(messages: 4), at: at(598)).cachedTokens, 1_750)
        // Nothing for 301 s: the entry is gone and the whole prefix is written again.
        let expired = cache.serve(snapshot(messages: 5), at: at(900))
        XCTAssertEqual(expired.cachedTokens, 0)
        XCTAssertNil(expired.matchedLevel)
    }

    func testOneHourTTLSurvivesALunchBreak() {
        var cache = PromptCache(ttl: .oneHour)
        cache.serve(snapshot(), at: at(0))
        XCTAssertEqual(cache.serve(snapshot(messages: 3), at: at(1_320)).cachedTokens, 1_700)
    }

    func testToolChangeInvalidatesEverything() {
        var cache = PromptCache()
        cache.serve(snapshot(), at: at(0))
        let result = cache.serve(snapshot(messages: 3, toolVersion: 2), at: at(30))
        XCTAssertEqual(result.cachedTokens, 0)
        XCTAssertNil(result.matchedLevel)
    }

    func testSystemChangeKeepsTheToolsEntry() {
        var cache = PromptCache()
        cache.serve(snapshot(), at: at(0))
        let result = cache.serve(snapshot(messages: 3, claudeVersion: 2), at: at(30))
        XCTAssertEqual(result.cachedTokens, 300, "the explicit breakpoint after the tool array still matches")
        XCTAssertEqual(result.matchedLevel, .tools)
    }

    func testRewritingAnEarlyMessageKeepsToolsAndSystem() {
        var cache = PromptCache()
        cache.serve(snapshot(messages: 4), at: at(0))
        var rewritten = snapshot(messages: 5)
        rewritten.messages[0].revision = 1
        let result = cache.serve(rewritten, at: at(30))
        XCTAssertEqual(result.matchedLevel, .system)
        XCTAssertEqual(result.cachedTokens, 1_600)
    }

    func testLookbackWindowLimitsHowFarBackAMatchIsFound() {
        // Two breakpoints only (tools, last message) and a very long transcript: with a 3-block window the
        // tools entry is unreachable from the last message, but the tools breakpoint itself still finds it.
        var cache = PromptCache(ttl: .fiveMinutes, lookback: 3)
        var long = snapshot(messages: 30)
        long.system = []
        cache.serve(long, at: at(0))
        var next = long
        next.messages[0].revision = 1
        next.messages.append(Message(role: .user, tokens: 50))
        let result = cache.serve(next, at: at(30))
        XCTAssertEqual(result.matchedLevel, .tools)
        XCTAssertEqual(result.cachedTokens, 300)
    }

    func testCostUsesReadAndWritePrices() {
        let result = CacheResult(cachedTokens: 1_000_000, uncachedTokens: 1_000_000, matchedBlockIndex: nil, matchedLevel: nil)
        XCTAssertEqual(result.cost(pricing: .fable51, ttl: .fiveMinutes), 0.25 + 12.5, accuracy: 0.0001)
        XCTAssertEqual(result.cost(pricing: .fable51, ttl: .oneHour), 0.25 + 20, accuracy: 0.0001)
        XCTAssertEqual(Pricing.fable51.readPerMillion / Pricing.fable51.inputPerMillion, 0.025, accuracy: 0.0001)
    }
}
