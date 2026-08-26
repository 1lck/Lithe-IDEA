import Foundation

extension AppModel {
    func connectGitHubWithDeviceFlow() async {
        await githubFeature.beginDeviceAuthorization(
            workspaceURL: workspaceURL,
            onAuthorization: { [weak self] authorization in
                guard let self else { return }
                self.platformUI.copyToClipboard(authorization.userCode)
                if let url = URL(string: authorization.verificationURI) {
                    self.platformUI.open(url)
                }
            }
        )
    }

    func connectGitHub(personalAccessToken: String) async {
        await githubFeature.connect(
            personalAccessToken: personalAccessToken,
            workspaceURL: workspaceURL
        )
    }

    func disconnectGitHub() async {
        await githubFeature.disconnect()
    }

    func checkoutSelectedPullRequest() async {
        if await githubFeature.checkout(workspaceURL: workspaceURL) {
            await refreshGit()
            showNotification("Pull request branch checked out")
        }
    }

    func publishGitHubPullRequestBranch(named name: String) async -> String? {
        let branch = await githubFeature.publishPullRequestBranch(
            named: name,
            workspaceURL: workspaceURL
        )
        if branch != nil {
            await refreshGit()
        }
        return branch
    }
}
