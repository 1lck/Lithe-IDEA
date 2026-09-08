import LitheGitModule

/// Caches the "current" reference lookup against the reference list it came from.
///
/// `GitLogView` asks for the current branch from more than twenty places in a
/// single body pass, and each ask was a linear scan of every branch, remote
/// branch, and tag in the repository.
///
/// A reference box in `@State`, like `EditorViewportStore`, so caching cannot
/// invalidate the view that reads it.
@MainActor
final class GitCurrentReferenceCache {
    private var cachedReferences: [GitReference] = []
    private var cachedResult: GitReference?
    private var hasCached = false

    func reference(in references: [GitReference]) -> GitReference? {
        if hasCached, cachedReferences == references { return cachedResult }
        let result = references.first(where: \.isCurrent)
        cachedReferences = references
        cachedResult = result
        hasCached = true
        return result
    }
}
