import Foundation
import LitheCoreContracts

/// The selected test scope, preserved when rerunning from the main toolbar.
struct ActiveTestTarget: Equatable, Sendable {
    let providerID: String
    let scope: LanguageTestScope
    /// Upstream launch title, when debug preparation resolves a file to an actual test class.
    var resolvedName: String? = nil

    var name: String {
        if let resolvedName { return resolvedName }
        return switch scope {
        case .workspace: String(localized: "Workspace")
        case .file(let url): url.lastPathComponent
        case .testCase(let identifier, _): Self.formattedName(for: identifier)
        }
    }

    /// Formats identifiers like `demo.CalculatorTest#intentionalFailureForPreview()`
    /// into `CalculatorTest.intentionalFailureForPreview`, or `demo.CalculatorTest` into `CalculatorTest`.
    static func formattedName(for identifier: String) -> String {
        if let hashIndex = identifier.firstIndex(of: "#") {
            let className = String(identifier[..<hashIndex])
            let methodName = String(identifier[identifier.index(after: hashIndex)...])
                .split(separator: "(", maxSplits: 1).first.map(String.init) ?? ""
            let shortClass = className.split(separator: ".").last.map(String.init) ?? className
            return "\(shortClass).\(methodName)"
        }
        let clean = identifier.split(separator: "(", maxSplits: 1).first.map(String.init) ?? identifier
        return clean.split(separator: ".").last.map(String.init) ?? clean
    }
}
