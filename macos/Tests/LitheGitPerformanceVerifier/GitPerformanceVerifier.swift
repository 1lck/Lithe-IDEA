import Foundation
import LitheGitModule
import LitheGitPerformanceSupport

@main
struct GitPerformanceVerifier {
    private static let scenarioCommitCounts = [1_000, 5_000]
    private static let sampleCount = 21
    private static let warmupCount = 3

    static func main() {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            let startedAt = ISO8601DateFormatter().string(from: Date())
            let scenarios = try scenarioCommitCounts.map(runScenario)
            try writeJSON(
                BenchmarkReport(
                    schemaVersion: 1,
                    benchmark: "git-graph-layout",
                    configuration: "release",
                    generatedAt: startedAt,
                    warmupCount: warmupCount,
                    sampleCount: sampleCount,
                    scenarios: scenarios
                ),
                to: options.output
            )
            print("Git graph Release baseline written to \(options.output.path)")
        } catch {
            FileHandle.standardError.write(Data("Git performance verification failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func runScenario(commitCount: Int) throws -> ScenarioResult {
        let commits = SyntheticGitGraphFixture.mergeHeavy(commitCount: commitCount)
        guard SyntheticGitGraphFixture.parentsFollowChildren(in: commits) else {
            throw VerificationError.invalidFixture(commitCount: commitCount)
        }
        let expected = GitGraphStructureBaseline.expected(commitCount: commitCount)
        let renderBenchmark = GitGraphRenderBenchmark(rowCount: commitCount)
        let committedSignature = GitGraphStructureBaseline.expectedSignature(commitCount: commitCount)
        var expectedSignature: UInt64?

        for _ in 0..<warmupCount {
            let layout = GitGraphLayoutService.layout(commits: commits)
            try validate(
                layout: layout,
                expected: expected,
                committedSignature: committedSignature,
                expectedSignature: &expectedSignature
            )
        }

        let clock = ContinuousClock()
        var samples: [Double] = []
        samples.reserveCapacity(sampleCount)
        for _ in 0..<sampleCount {
            let start = clock.now
            let layout = GitGraphLayoutService.layout(commits: commits)
            let elapsed = milliseconds(clock.now - start)
            guard elapsed.isFinite, elapsed >= 0 else {
                throw VerificationError.invalidSample(commitCount: commitCount, milliseconds: elapsed)
            }
            try validate(
                layout: layout,
                expected: expected,
                committedSignature: committedSignature,
                expectedSignature: &expectedSignature
            )
            samples.append(elapsed)
        }

        guard let signature = expectedSignature, samples.count == sampleCount else {
            throw VerificationError.missingSamples(commitCount: commitCount)
        }
        let sorted = samples.sorted()
        return ScenarioResult(
            commitCount: commitCount,
            samplesMs: samples,
            medianMs: percentile(0.50, in: sorted),
            p95Ms: percentile(0.95, in: sorted),
            minimumMs: sorted[0],
            maximumMs: sorted[sorted.count - 1],
            signature: signatureString(signature),
            structureBaseline: expected,
            renderBenchmark: renderBenchmark
        )
    }

    private static func validate(
        layout: GitGraphLayout,
        expected: GitGraphStructureBaseline,
        committedSignature: UInt64,
        expectedSignature: inout UInt64?
    ) throws {
        let actual = GitGraphStructureBaseline(layout: layout)
        guard actual == expected else {
            throw VerificationError.workBaselineMismatch(expected: expected, actual: actual)
        }
        guard GitGraphStructureBaseline.hasContinuousLanes(layout) else {
            throw VerificationError.discontinuousLane
        }
        let signature = GitGraphStructureBaseline.signature(of: layout)
        guard signature == committedSignature else {
            throw VerificationError.signatureMismatch(expected: committedSignature, actual: signature)
        }
        if let expectedSignature, signature != expectedSignature {
            throw VerificationError.signatureMismatch(expected: expectedSignature, actual: signature)
        }
        expectedSignature = signature
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func percentile(_ percentile: Double, in sorted: [Double]) -> Double {
        let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
        return sorted[min(rank - 1, sorted.count - 1)]
    }

    private static func signatureString(_ signature: UInt64) -> String {
        let hexadecimal = String(signature, radix: 16)
        return "0x" + String(repeating: "0", count: 16 - hexadecimal.count) + hexadecimal
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

private struct Options {
    let output: URL

    init(arguments: [String]) throws {
        var output: URL?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--output":
                index += 1
                guard index < arguments.count else { throw VerificationError.missingArgumentValue("--output") }
                output = URL(fileURLWithPath: arguments[index])
            default:
                throw VerificationError.unknownArgument(arguments[index])
            }
            index += 1
        }
        guard let output else { throw VerificationError.missingArgument("--output") }
        self.output = output
    }
}

private struct BenchmarkReport: Codable {
    let schemaVersion: Int
    let benchmark: String
    let configuration: String
    let generatedAt: String
    let warmupCount: Int
    let sampleCount: Int
    let scenarios: [ScenarioResult]
}

private struct ScenarioResult: Codable {
    let commitCount: Int
    let samplesMs: [Double]
    let medianMs: Double
    let p95Ms: Double
    let minimumMs: Double
    let maximumMs: Double
    let signature: String
    let structureBaseline: GitGraphStructureBaseline
    let renderBenchmark: GitGraphRenderBenchmark
}

private enum VerificationError: Error, CustomStringConvertible {
    case unknownArgument(String)
    case missingArgument(String)
    case missingArgumentValue(String)
    case invalidSample(commitCount: Int, milliseconds: Double)
    case invalidFixture(commitCount: Int)
    case missingSamples(commitCount: Int)
    case workBaselineMismatch(expected: GitGraphStructureBaseline, actual: GitGraphStructureBaseline)
    case signatureMismatch(expected: UInt64, actual: UInt64)
    case discontinuousLane

    var description: String {
        switch self {
        case let .unknownArgument(argument): "unknown argument \(argument)"
        case let .missingArgument(argument): "missing required argument \(argument)"
        case let .missingArgumentValue(argument): "missing value for \(argument)"
        case let .invalidSample(commitCount, milliseconds):
            "invalid \(commitCount)-commit sample: \(milliseconds)ms"
        case let .invalidFixture(commitCount):
            "invalid \(commitCount)-commit fixture: hashes must be unique and every parent must follow its child"
        case let .missingSamples(commitCount): "missing samples for \(commitCount)-commit scenario"
        case let .workBaselineMismatch(expected, actual):
            "work baseline mismatch: expected \(expected), got \(actual)"
        case let .signatureMismatch(expected, actual):
            "layout signature mismatch: expected \(expected), got \(actual)"
        case .discontinuousLane: "layout contains a discontinuous lane"
        }
    }
}
