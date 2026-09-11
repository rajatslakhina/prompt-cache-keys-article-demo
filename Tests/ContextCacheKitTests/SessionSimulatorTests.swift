import XCTest
@testable import ContextCacheKit

final class SessionSimulatorTests: XCTestCase {
    private let simulator = SessionSimulator()

    func testBaselineLedger() {
        let report = simulator.run(Fixture.baseline)
        XCTAssertEqual(report.sharedPrefixTokens, 36_840)
        XCTAssertEqual(report.requestCount, 40)
        XCTAssertEqual(report.missCount, 7)
        XCTAssertEqual(report.hitRatio, 0.856, accuracy: 0.001)
        XCTAssertEqual(report.tokensRecached, 255_071)
        XCTAssertEqual(report.cost, 4.65, accuracy: 0.01)
        XCTAssertEqual(report.idealCost, 1.53, accuracy: 0.01)
        XCTAssertEqual(report.overspend, 3.12, accuracy: 0.01)

        let causes = report.causes.map(\.category)
        XCTAssertEqual(causes, ["tool set changed", "system prompt changed", "idle past TTL",
                                "tool order changed", "message prefix rewritten"])
        XCTAssertEqual(report.causes[0].tokensRecached, 74_412)
        XCTAssertEqual(report.causes[1].turns, 3)
    }

    func testBaselineMissTurnsAndBlastRadius() {
        let report = simulator.run(Fixture.baseline)
        let misses = report.turns.filter { !$0.isHit }
        XCTAssertEqual(misses.map(\.turn), [2, 8, 14, 20, 26, 33, 37])

        let byTurn = Dictionary(uniqueKeysWithValues: misses.map { ($0.turn, $0) })
        XCTAssertEqual(byTurn[37]?.result.cachedTokens, 0, "a 30-token schema change re-sends the whole request")
        XCTAssertEqual(byTurn[37]?.result.uncachedTokens, 75_249)
        XCTAssertEqual(byTurn[26]?.result.matchedLevel, .tools, "a CLAUDE.md edit keeps the tool array cached")
        XCTAssertEqual(byTurn[26]?.result.cachedTokens, 19_140)
        XCTAssertEqual(byTurn[14]?.result.cachedTokens, 0, "reordering tools is as bad as changing them")
        XCTAssertEqual(byTurn[2]?.tokensRecached, 157, "the changelog bug is the cheapest miss on the ledger")
    }

    func testSixMissesCostMoreThanTheOtherThirtyFourTurns() {
        let report = simulator.run(Fixture.baseline)
        let missCost = report.turns.filter { !$0.isHit }.reduce(0) { $0 + $1.cost }
        let hitCost = report.turns.filter(\.isHit).reduce(0) { $0 + $1.cost }
        XCTAssertGreaterThan(missCost, hitCost)
        XCTAssertEqual(missCost, 3.41, accuracy: 0.01)
        XCTAssertEqual(hitCost, 1.24, accuracy: 0.01)
    }

    func testStabilizedLeavesOnlyTheLunchBreak() {
        let report = simulator.run(Fixture.stabilized)
        XCTAssertEqual(report.missCount, 1)
        XCTAssertEqual(report.causes.map(\.category), ["idle past TTL"])
        XCTAssertEqual(report.hitRatio, 0.942, accuracy: 0.001)
        XCTAssertEqual(report.cost, 2.22, accuracy: 0.01)
        XCTAssertEqual(report.overspend, 0.69, accuracy: 0.01)
    }

    func testOneHourTTLRemovesTheLastMissAndStillComesOutCheaper() {
        let fiveMinute = simulator.run(Fixture.stabilized)
        let oneHour = simulator.run(Fixture.stabilizedOneHour)
        XCTAssertEqual(oneHour.missCount, 0)
        XCTAssertEqual(oneHour.tokensRecached, 0)
        XCTAssertEqual(oneHour.overspend, 0, accuracy: 0.0001)
        XCTAssertEqual(oneHour.cost, 2.11, accuracy: 0.01)
        XCTAssertLessThan(oneHour.cost, fiveMinute.cost)
        XCTAssertLessThan(fiveMinute.cost - oneHour.cost, 0.15, "the margin is thin: one lunch break versus 40 turns of write premium")
    }

    func testSkillPlacementDecidesWhetherLoadingIsAMiss() {
        func script(_ placement: SkillPlacement) -> SessionScript {
            SessionScript(name: "skill", initial: Fixture.initialSnapshot, events: [
                .user(tokens: 100, after: 0), .assistant(tokens: 100),
                .loadSkill(name: "skill:x", tokens: 3_000, placement: placement),
                .user(tokens: 100, after: 30),
            ])
        }
        let spliced = simulator.run(script(.systemPrompt)).turns[1]
        let appended = simulator.run(script(.appendedMessage)).turns[1]
        XCTAssertEqual(spliced.cause, .systemSegmentChanged(segments: ["skill:x"]))
        XCTAssertEqual(spliced.tokensRecached, 100, "appending to the system prompt re-sends the transcript after it")
        XCTAssertEqual(appended.cause, .none)
        XCTAssertEqual(appended.tokensRecached, 0)
        XCTAssertEqual(appended.newTokens, 3_200)
    }

    func testNoOpEventsDoNotCauseMisses() {
        let script = SessionScript(name: "noop", initial: Fixture.initialSnapshot, events: [
            .user(tokens: 100, after: 0), .assistant(tokens: 100),
            .rewriteMessage(index: 99),
            .editSegment(name: "does-not-exist", newTokens: 1),
            .reconnectServer(prefix: "nothing."),
            .user(tokens: 100, after: 30),
        ])
        let report = simulator.run(script)
        XCTAssertEqual(report.missCount, 0)
        XCTAssertEqual(report.turns[1].cause, .none)
    }

    func testRerenderingAnUnknownToolAddsIt() {
        let script = SessionScript(name: "add", initial: Fixture.initialSnapshot, events: [
            .user(tokens: 100, after: 0), .assistant(tokens: 100),
            .rerenderTool(name: "NewTool", tokens: 300),
            .user(tokens: 100, after: 30),
        ])
        let report = simulator.run(script)
        XCTAssertEqual(report.turns[1].cause, .toolSetChanged(added: ["NewTool"], removed: [], changed: []))
        XCTAssertEqual(report.turns[1].result.cachedTokens, 0)
    }

    func testTotalsAreSumsOfTurns() {
        let report = simulator.run(Fixture.baseline)
        XCTAssertEqual(report.cost, report.turns.reduce(0) { $0 + $1.cost }, accuracy: 0.000001)
        XCTAssertEqual(report.totalInputTokens, report.turns.reduce(0) { $0 + $1.result.totalTokens })
        XCTAssertEqual(report.turns.first?.cause, MissCause.none)
        XCTAssertEqual(report.turns.first?.result.cachedTokens, 0)
    }
}
