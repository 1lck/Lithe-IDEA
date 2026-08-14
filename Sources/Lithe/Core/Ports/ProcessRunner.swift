import Foundation
import LitheCoreContracts
import LitheGitModule

typealias ProcessRequest = LitheCoreContracts.ProcessRequest
typealias ProcessLifecycleState = LitheCoreContracts.ProcessLifecycleState
typealias ProcessLifecycleEvent = LitheCoreContracts.ProcessLifecycleEvent

struct ProcessResult: Sendable {
    let output: String
    let exitCode: Int32
    let stashRestoreConflict: GitStashRestoreConflict?

    init(
        output: String,
        exitCode: Int32,
        stashRestoreConflict: GitStashRestoreConflict? = nil
    ) {
        self.output = output
        self.exitCode = exitCode
        self.stashRestoreConflict = stashRestoreConflict
    }

    var succeeded: Bool { exitCode == 0 }
}

protocol ProcessRunner: Sendable {
    func run(_ request: ProcessRequest) -> ProcessResult
}

protocol GitCommandRunner: Sendable {
    func run(
        arguments: [String],
        workingDirectory: String,
        input: String?
    ) -> ProcessResult
}
