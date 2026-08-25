import Foundation

enum FeatureModuleSleepError: LocalizedError {
    case activeWork(String)

    var errorDescription: String? {
        switch self {
        case .activeWork(let message): message
        }
    }
}
