import Testing
@testable import Lithe
@testable import LitheGitModule

/// `GitReferenceRowView` compares itself with `==` so a `LazyVStack` row is only
/// re-evaluated when something it shows changes. Its "Tracking Branch" submenu
/// reads the workspace's remote branches, so a `refs` refresh that only adds or
/// drops remote branches has to invalidate the row too; otherwise the row keeps
/// the menu it built earlier and offers a remote branch list that no longer
/// exists — or keeps saying "No Remote Branches" after one appeared.
@Suite("Git reference row render key")
struct GitReferenceRowRenderKeyTests {
    private func localBranch(_ shortName: String) -> GitReference {
        GitReference(
            fullName: "refs/heads/\(shortName)",
            shortName: shortName,
            kind: .local,
            isCurrent: false,
            upstreamShortName: nil
        )
    }

    private func remoteBranch(_ shortName: String) -> GitReference {
        GitReference(
            fullName: "refs/remotes/\(shortName)",
            shortName: shortName,
            kind: .remote,
            isCurrent: false,
            upstreamShortName: nil
        )
    }

    /// A row whose own branch and every other compared field are held constant
    /// except the ones a test varies explicitly.
    private func key(
        remoteBranches: [GitReference],
        isSelected: Bool = false
    ) -> GitReferenceRowRenderKey {
        GitReferenceRowRenderKey(
            row: GitReferenceRow(
                id: "reference:feature/x",
                name: "feature/x",
                depth: 0,
                content: .reference(localBranch("feature/x"))
            ),
            isSelected: isSelected,
            isPerformingBranchOperation: false,
            currentReferenceID: "refs/heads/main",
            comparisonSourceID: nil,
            isReadOnly: false,
            repositoryColorIndex: nil,
            remoteBranches: remoteBranches
        )
    }

    @Test("a refresh that only gains a remote branch invalidates the row")
    func gainingARemoteBranchInvalidatesTheRow() {
        #expect(key(remoteBranches: []) != key(remoteBranches: [remoteBranch("origin/main")]))
    }

    @Test("a refresh that only drops a remote branch invalidates the row")
    func droppingARemoteBranchInvalidatesTheRow() {
        #expect(
            key(remoteBranches: [remoteBranch("origin/main"), remoteBranch("origin/release")])
                != key(remoteBranches: [remoteBranch("origin/main")])
        )
    }

    @Test("an unchanged remote branch list keeps the row equal")
    func stableRemoteBranchListKeepsTheRowEqual() {
        #expect(
            key(remoteBranches: [remoteBranch("origin/main")])
                == key(remoteBranches: [remoteBranch("origin/main")])
        )
    }

    @Test("a changed row still invalidates the row with a stable remote branch list")
    func changedRowStillInvalidatesTheRow() {
        let remoteBranches = [remoteBranch("origin/main")]

        #expect(key(remoteBranches: remoteBranches) != key(remoteBranches: remoteBranches, isSelected: true))
    }
}
