import Foundation
@testable import Lithe

/// Window and run-lifecycle tests do not inspect Java indexes or installed Maven
/// artifacts. Keep their unrelated background work independent of the host,
/// including when the test executable links the real Rust Core.
struct NoProjectJavaOperations: JavaMavenOperations {
    func scanMavenProject(at rootURL: URL, files: [URL]) -> MavenProject? { nil }
    func mavenDiagnostics(output: String, projectRoot: URL) -> [MavenBuildIssue] { [] }
    func codeVision(at rootURL: URL, targetPath: String, paths: [String]) -> [JavaCodeVisionValue] { [] }
    func className(source: String, simpleName: String) -> String? { nil }
    func sourceDefinition(source: String, declarationName: String, memberName: String?) -> (line: Int, utf16Column: Int)? { nil }
    func serverPort(content: String, fileExtension: String) -> Int? { nil }
    func scanRunConfigurations(at rootURL: URL, files: [URL], mavenProject: MavenProject?) -> [JavaRunConfiguration] { [] }
    func structure(source: String, declarationSources: [String]) -> JavaStructureResult? { nil }
}
