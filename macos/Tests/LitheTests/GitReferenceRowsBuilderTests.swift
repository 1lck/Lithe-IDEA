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
