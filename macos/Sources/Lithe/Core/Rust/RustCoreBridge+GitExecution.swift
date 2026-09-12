import Foundation
import LitheGitModule
import LitheRustCore

extension RustCoreBridge {
    /// The C call is synchronous; this box remains owned until all callbacks end.
    func executeGitObserving(_ request: String, context: GitExecutionContext?) -> UnsafeMutablePointer<CChar>? {
        guard let context else { return lithe_bridge_execute_json(request) }
        return withExtendedLifetime(context) {
            lithe_bridge_execute_json_with_events(request, { pointer, opaque in
                guard let pointer, let opaque else { return }
                let context = Unmanaged<GitExecutionContext>.fromOpaque(opaque).takeUnretainedValue()
                guard let data = String(cString: pointer).data(using: .utf8),
                      let event = try? JSONDecoder().decode(GitExecutionEvent.self, from: data) else { return }
                if event.type == "requestStarted", context.isCancellationRequested {
                    context.operationID.withCString { _ = lithe_bridge_cancel($0) }
                }
                context.receive(event)
            }, Unmanaged.passUnretained(context).toOpaque())
        }
    }
}
