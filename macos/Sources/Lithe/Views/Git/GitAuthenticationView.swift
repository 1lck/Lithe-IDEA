import SwiftUI
import LitheGitModule

struct GitAuthenticationHost: View {
    @ObservedObject var feature: GitFeatureModel
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(item: Binding(get: { feature.authenticationChallenges.first }, set: { _ in })) { challenge in
                GitAuthenticationView(challenge: challenge) { answer in
                    Task { await feature.answerAuthentication(challenge, answer: answer) }
                }
                .interactiveDismissDisabled()
            }
    }
}

private struct GitAuthenticationView: View {
    let challenge: GitAuthenticationChallenge
    let reply: (String?) -> Void
    @State private var answer = ""
    @State private var submitted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Git authentication").font(.headline)
            Text(verbatim: challenge.prompt).textSelection(.enabled)
            if challenge.attempt > 1 { Text("Git requested credentials again. Check the previous answer.").foregroundStyle(LitheTheme.warning) }
            if challenge.retry { Text("Retry uses Lithe authentication for this operation only.") }
            else if challenge.secret { SecureField("Password or passphrase", text: $answer).textFieldStyle(.roundedBorder) }
            else { TextField("Response", text: $answer).textFieldStyle(.roundedBorder) }
            Text("This response is sent only to the running Git operation.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { submit(nil) }.keyboardShortcut(.cancelAction)
                Button(challenge.retry ? "Retry" : "Continue") { submit(challenge.retry ? "retry" : answer) }.keyboardShortcut(.defaultAction)
            }.disabled(submitted)
        }.padding(24).frame(width: 500)
    }
    private func submit(_ value: String?) { submitted = true; answer = ""; reply(value) }
}
