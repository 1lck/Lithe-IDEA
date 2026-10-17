import Foundation
import LitheCoreContracts

/// Represents an active or recently executed test target (class or method),
/// displayed in the main workbench toolbar run configuration picker with
/// its test name and JUnit icon.
struct ActiveTestTarget: Equatable, Sendable {
    let name: String
    let providerID: String
    let identifier: String
    let fileURL: URL?

    init(name: String, providerID: String, identifier: String, fileURL: URL? = nil) {
        self.name = name
        self.providerID = providerID
        self.identifier = identifier
        self.fileURL = fileURL
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
