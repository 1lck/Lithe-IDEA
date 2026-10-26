import LitheModuleAPI
import Foundation
import LitheCoreContracts

public enum DebugAdapterProtocolError: LocalizedError {
    case notReady
    case stopped
    case invalidResponse(String)
    case requestFailed(command: String, message: String)
    case cancelled(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .notReady:
            L10n.string("The Debug Adapter is not ready.")
        case .stopped:
            L10n.string("The Debug Adapter stopped.")
        case .invalidResponse(let command):
            L10n.string("The Debug Adapter returned an invalid \(command) response.")
        case .requestFailed(let command, let message):
            L10n.string("\(command) failed: \(message)")
        case .cancelled(let command):
            L10n.string("\(command) was cancelled.")
        case .timedOut(let command):
            L10n.string("\(command) timed out.")
        }
    }
}
