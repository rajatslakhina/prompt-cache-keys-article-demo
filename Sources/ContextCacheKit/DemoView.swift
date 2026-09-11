#if canImport(SwiftUI)
import SwiftUI

/// Replays the fixture sessions and shows the ledger: hit ratio, dollars, and the causes ranked by cost.
public struct ContextCacheDemoView: View {
    private enum Variant: String, CaseIterable, Identifiable {
        case baseline = "Baseline", stabilized = "Stabilized", oneHour = "Stabilized · 1h"
        var id: String { rawValue }
        var script: SessionScript {
            switch self {
            case .baseline: return Fixture.baseline
            case .stabilized: return Fixture.stabilized
            case .oneHour: return Fixture.stabilizedOneHour
            }
        }
    }

    @State private var variant: Variant = .baseline
    private let simulator = SessionSimulator()

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Session", selection: $variant) {
                        ForEach(Variant.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }

                let report = simulator.run(variant.script)

                Section("Session") {
                    metric("Shared prefix", "\(report.sharedPrefixTokens.formatted()) tokens")
                    metric("Requests", "\(report.requestCount)")
                    metric("Cache hit ratio", report.hitRatio.formatted(.percent.precision(.fractionLength(1))))
                    metric("Misses", "\(report.missCount)")
                    metric("Tokens re-cached", report.tokensRecached.formatted())
                    metric("Input cost", dollars(report.cost))
                    metric("Ideal cost", dollars(report.idealCost))
                    metric("Overspend", dollars(report.overspend))
                        .foregroundStyle(report.overspend > 0.01 ? Color.red : Color.green)
                }

                Section("Causes, ranked by dollars") {
                    if report.causes.isEmpty {
                        Text("No misses after the first request.").foregroundStyle(.secondary)
                    }
                    ForEach(report.causes) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(line.category).font(.headline)
                                Spacer()
                                Text(dollars(line.overspend)).monospacedDigit()
                            }
                            Text("\(line.turns) turn\(line.turns == 1 ? "" : "s") · \(line.tokensRecached.formatted()) tokens re-cached")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Ledger") {
                    ForEach(report.turns) { turn in
                        HStack(alignment: .firstTextBaseline) {
                            Text("#\(turn.turn)").monospacedDigit().frame(width: 36, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(turn.cause.description)
                                    .font(turn.isHit ? .body : .body.weight(.semibold))
                                Text("\(turn.result.cachedTokens.formatted()) cached · \(turn.result.uncachedTokens.formatted()) written")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(dollars(turn.cost)).monospacedDigit()
                                .foregroundStyle(turn.isHit ? Color.secondary : Color.red)
                        }
                    }
                }
            }
            .navigationTitle("Prompt Cache Ledger")
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func dollars(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}

#Preview {
    ContextCacheDemoView()
}
#endif
