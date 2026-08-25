import Foundation

/// Routes operating-system URL callbacks to an application authorization workflow.
@MainActor
protocol ExternalAuthorizationCallbackRouting: AnyObject {
    func installHandler(_ handler: @escaping @MainActor (URL) -> Void)
}
