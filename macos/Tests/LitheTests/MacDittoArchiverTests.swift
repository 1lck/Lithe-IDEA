import Foundation
import Testing
@testable import Lithe

private struct ArchiveFixtureRunner: ProcessRunner {
    let exitCode: Int32
    func run(_ request: ProcessRequest) -> ProcessResult {
        if let output = request.arguments.last {
            do { try Data("new archive".utf8).write(to: URL(fileURLWithPath: output)) }
            catch { Issue.record("Could not create archive fixture: \(error)") }
        }
        return ProcessResult(output: "synthetic archiver result", exitCode: exitCode)
    }
}

@Suite("Diagnostic archive publication")
struct MacDittoArchiverTests {
    @Test(arguments: [Int32(0), Int32(1)])
    func archivePublicationPreservesExistingOutputOnFailure(exitCode: Int32) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("existing.zip")
        try Data("previous archive".utf8).write(to: destination)
        let archiver = MacDittoArchiver(processRunner: ArchiveFixtureRunner(exitCode: exitCode))
        if exitCode == 0 { try archiver.archive(directoryURL: root, toZipURL: destination) }
        else { #expect(throws: DiagnosticsArchivingError.self) { try archiver.archive(directoryURL: root, toZipURL: destination) } }
        let text = try String(contentsOf: destination, encoding: .utf8)
        #expect(text == (exitCode == 0 ? "new archive" : "previous archive"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["existing.zip"])
    }
}
