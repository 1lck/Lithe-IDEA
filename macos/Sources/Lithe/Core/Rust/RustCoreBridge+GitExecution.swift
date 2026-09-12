import Foundation
import LitheGitModule
import LitheRustCore

/// One synchronous C call owns its receiver until the final callback returns.
private final class GitExecutionReceiver {
    let context: GitExecutionContext?
    let journal: GitExecutionJournal?

    init(context: GitExecutionContext?, journal: GitExecutionJournal?) {
        self.context = context
        self.journal = journal
    }

    func receive(_ event: GitExecutionEvent) {
        if let context {
            if event.type == "requestStarted", context.isCancellationRequested {
                context.operationID.withCString { _ = lithe_bridge_cancel($0) }
            }
            context.receive(event)
        } else {
            journal?.receive(event)
        }
    }
}

extension RustCoreBridge {
    func executeGitObserving(
        _ request: String, context: GitExecutionContext?, journal: GitExecutionJournal? = nil
    ) -> UnsafeMutablePointer<CChar>? {
        guard context != nil || journal != nil else { return lithe_bridge_execute_json(request) }
        let receiver = GitExecutionReceiver(context: context, journal: journal)
        return withExtendedLifetime(receiver) {
            lithe_bridge_execute_json_with_events(request, { pointer, opaque in
                guard let pointer, let opaque else { return }
                let receiver = Unmanaged<GitExecutionReceiver>.fromOpaque(opaque).takeUnretainedValue()
                guard let data = String(cString: pointer).data(using: .utf8),
                      let event = try? JSONDecoder().decode(GitExecutionEvent.self, from: data) else { return }
                receiver.receive(event)
            }, Unmanaged.passUnretained(receiver).toOpaque())
        }
    }
}
