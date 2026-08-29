import Foundation

extension AppModel {
    func connectGitHubWithDeviceFlow() async {
        guard LitheFeatureAvailability.githubPullRequests else { return }
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
        guard LitheFeatureAvailability.githubPullRequests else { return }
        await githubFeature.connect(
            personalAccessToken: personalAccessToken,
            workspaceURL: workspaceURL
        )
    }

    func disconnectGitHub() async {
        guard LitheFeatureAvailability.githubPullRequests else { return }
        await githubFeature.disconnect()
    }

    func checkoutSelectedPullRequest() async {
        guard LitheFeatureAvailability.githubPullRequests else { return }
        if await githubFeature.checkout(workspaceURL: workspaceURL) {
            await refreshGit()
            showNotification("Pull request branch checked out")
        }
    }

    func publishGitHubPullRequestBranch(named name: String) async -> String? {
        guard LitheFeatureAvailability.githubPullRequests else { return nil }
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
