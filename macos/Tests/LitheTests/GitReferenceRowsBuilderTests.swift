import Testing
@testable import Lithe
@testable import LitheGitModule

/// The reference tree used to render as a recursive `AnyView`; flattening it to
/// rows moved ordering, nesting, and collapse handling out of the view. These
/// tests pin that behavior, because a wrong row order or a missing collapse
/// silently reshuffles the user's branch list.
@Suite("Git reference rows")
struct GitReferenceRowsBuilderTests {
    private func reference(
        _ shortName: String,
        kind: GitReferenceKind = .local,
        isCurrent: Bool = false
    ) -> GitReference {
        GitReference(
            fullName: "refs/heads/\(shortName)",
            shortName: shortName,
            kind: kind,
            isCurrent: isCurrent,
            upstreamShortName: nil
        )
    }

    private func rows(
        _ shortNames: [String],
        collapsed: Set<String> = []
    ) -> [GitReferenceRow] {
        GitReferenceRowsBuilder.rows(
            from: shortNames.map { reference($0) },
            kind: .local,
            collapsedGroups: collapsed
        )
    }

    @Test
    func flatReferencesBecomeOneRowEach() {
        let result = rows(["main", "develop"])

        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.depth == 0 })
        // Natural ordering, not insertion order.
        #expect(result.map(\.name) == ["develop", "main"])
    }

    @Test
    func aSlashSeparatedNameNestsUnderAGroup() {
        let result = rows(["feature/login"])

        #expect(result.count == 2)
        #expect(result[0].name == "feature")
        #expect(result[0].depth == 0)
        if case .group = result[0].content {} else {
            Issue.record("the shared prefix should render as a group row")
        }
        #expect(result[1].name == "login")
        #expect(result[1].depth == 1)
        if case .reference = result[1].content {} else {
            Issue.record("the leaf should render as a reference row")
        }
    }

    @Test
    func deepPathsNestOneLevelPerComponent() {
        let result = rows(["refs/heads/a/b/c"])
        #expect(result.map(\.depth) == [0, 1, 2, 3, 4])
        #expect(result.map(\.name) == ["refs", "heads", "a", "b", "c"])
    }

    @Test
    func collapsingAGroupHidesItsDescendantsButKeepsTheGroup() {
        let expanded = rows(["feature/login", "feature/signup", "main"])
        let collapsed = rows(
            ["feature/login", "feature/signup", "main"],
            collapsed: ["local:feature"]
        )

        #expect(expanded.map(\.name) == ["main", "feature", "login", "signup"])
        // The group row survives so the user can expand it again.
        #expect(collapsed.map(\.name) == ["main", "feature"])
        if case .group(_, let isCollapsed) = collapsed[1].content {
            #expect(isCollapsed)
        } else {
            Issue.record("expected the feature group row")
        }
    }

    @Test
    func aNameThatIsBothABranchAndAPrefixEmitsTwoRows() {
        // `feature` is a branch and also the parent of `feature/login`, which the
        // recursive renderer handled by drawing both a reference and a group.
        let result = rows(["feature", "feature/login"])

        #expect(result.count == 3)
        #expect(result[0].name == "feature")
        if case .reference = result[0].content {} else {
            Issue.record("the branch itself should come first")
        }
        #expect(result[1].name == "feature")
        if case .group = result[1].content {} else {
            Issue.record("the shared prefix should follow as a group")
        }
        #expect(result[2].name == "login")
        // Two rows for one path still need distinct identities.
        #expect(result[0].id != result[1].id)
    }

    @Test
    func referencesSortBeforeFoldersAtTheSameLevel() {
        let result = rows(["zebra", "alpha/nested"])
        #expect(result.map(\.name) == ["zebra", "alpha", "nested"])
    }

    @Test
    func everyRowIdentifierIsUnique() {
        let result = rows(["feature", "feature/login", "feature/signup", "main", "release/1.0"])
        #expect(Set(result.map(\.id)).count == result.count)
    }

    @Test
    func theCollapseKeyIsScopedByReferenceKind() {
        // Local and remote sections can hold the same path; their collapse state
        // must not be shared.
        let remote = GitReferenceRowsBuilder.rows(
            from: [reference("feature/login", kind: .remote)],
            kind: .remote,
            collapsedGroups: ["local:feature"]
        )
        #expect(remote.count == 2, "a local collapse key must not collapse the remote group")
    }
}

/// The Git Log groups references by repository, but every branch write still
/// runs against the single active repository. These tests pin that a repository
/// group the user has not selected offers no context menu at all, so no entry
/// can silently mutate or compare against the wrong repository.
@Suite("Git reference row menu")
struct GitReferenceRowMenuTests {
    private func entries(
        kind: GitReferenceKind = .local,
        isCurrent: Bool = false,
        showsCompareWithCurrent: Bool = false,
        showsCompareWithSource: Bool = false,
        isPerforming: Bool = false,
        isReadOnly: Bool = false
    ) -> [GitReferenceMenuEntry] {
        GitReferenceRowMenu.entries(
            kind: kind,
            isCurrent: isCurrent,
            showsCompareWithCurrent: showsCompareWithCurrent,
            showsCompareWithSource: showsCompareWithSource,
            isPerformingBranchOperation: isPerforming,
            isReadOnly: isReadOnly
        )
    }

    @Test
    func readOnlyRowsOfferNoContextMenuAtAll() {
        #expect(entries(isReadOnly: true).isEmpty)
        #expect(entries(kind: .remote, isReadOnly: true).isEmpty)
        #expect(entries(kind: .tag, isReadOnly: true).isEmpty)
        #expect(entries(isCurrent: true, isReadOnly: true).isEmpty)
    }

    @Test
    func activeRowsOfferTheFullLocalBranchMenu() {
        let result = entries()
        #expect(result.contains(.action(.newBranch, isEnabled: true, isDestructive: false)))
        #expect(result.contains(.action(.checkout, isEnabled: true, isDestructive: false)))
        #expect(result.contains(.action(.merge, isEnabled: true, isDestructive: false)))
        #expect(result.contains(.action(.push, isEnabled: true, isDestructive: false)))
        #expect(result.contains(.action(.delete, isEnabled: true, isDestructive: true)))
        #expect(result.contains(.action(.rename, isEnabled: true, isDestructive: false)))
        // Update applies only to the checked-out branch.
        #expect(result.contains(.action(.update, isEnabled: false, isDestructive: false)))
    }

    @Test
    func currentBranchEnablesUpdateAndHidesDelete() {
        let result = entries(isCurrent: true)
        #expect(result.contains(.action(.update, isEnabled: true, isDestructive: false)))
        #expect(!result.contains(.action(.delete, isEnabled: true, isDestructive: true)))
        // A checked-out branch cannot be checked out again.
        #expect(!result.contains(.action(.checkout, isEnabled: true, isDestructive: false)))
    }

    @Test
    func tagRowsOfferNoBranchRebaseEntries() {
        let result = entries(kind: .tag)
        #expect(result.contains(.action(.checkout, isEnabled: true, isDestructive: false)))
        #expect(!result.contains(.action(.merge, isEnabled: true, isDestructive: false)))
        #expect(!result.contains(.action(.rebase, isEnabled: true, isDestructive: false)))
        #expect(!result.contains(.action(.checkoutAndRebase, isEnabled: true, isDestructive: false)))
    }

    @Test
    func remoteRowsOfferPullEntries() {
        let result = entries(kind: .remote)
        #expect(result.contains(.action(.pullRebase, isEnabled: true, isDestructive: false)))
        #expect(result.contains(.action(.pullMerge, isEnabled: true, isDestructive: false)))
        #expect(!result.contains(.action(.push, isEnabled: true, isDestructive: false)))
    }

    @Test
    func branchOperationInProgressDisablesBranchWrites() {
        let result = entries(isPerforming: true)
        for entry in result {
            guard case .action(let action, let isEnabled, _) = entry else { continue }
            switch action {
            case .checkout, .checkoutAndRebase, .merge, .rebase,
                 .pullRebase, .pullMerge, .update, .push, .delete, .rename,
                 .trackingBranch:
                #expect(!isEnabled)
            case .newBranch, .showDiffWithWorkingTree, .compareWithCurrent,
                 .compareWithSelectedSource, .selectForCompare, .copyBranchName:
                break
            }
        }
    }

    @Test
    func compareEntriesFollowTheAvailableComparisonContext() {
        let result = entries(showsCompareWithCurrent: true, showsCompareWithSource: true)
        #expect(result.contains(.action(.compareWithCurrent, isEnabled: true, isDestructive: false)))
        #expect(result.contains(.action(.compareWithSelectedSource, isEnabled: true, isDestructive: false)))
        #expect(!result.contains(.action(.selectForCompare, isEnabled: true, isDestructive: false)))
    }

    @Test
    func localAndRemoteRowsOfferCopyBranchNameButTagsDoNot() {
        for kind in [GitReferenceKind.local, .remote] {
            #expect(entries(kind: kind).contains(.action(.copyBranchName, isEnabled: true, isDestructive: false)))
        }
        #expect(!entries(kind: .tag).contains(.action(.copyBranchName, isEnabled: true, isDestructive: false)))
    }

    @Test
    func onlyLocalRowsOfferTrackingBranch() {
        #expect(entries(kind: .local).contains(.action(.trackingBranch, isEnabled: true, isDestructive: false)))
        #expect(!entries(kind: .remote).contains(.action(.trackingBranch, isEnabled: true, isDestructive: false)))
        #expect(!entries(kind: .tag).contains(.action(.trackingBranch, isEnabled: true, isDestructive: false)))
    }
}
