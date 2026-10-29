import Foundation

/// Logical comparison identity, scoped to its repository. Status changes do not
/// duplicate a working-file tab; different revisions of that file remain distinct.
struct RepositoryDiffTabKey: Hashable {
    enum Source: Hashable {
        case workingFile(URL)
        case directory(URL)
        case commit(String, String)
        case saved(String, String, String)
        case references(String, String?)
    }

    let repositoryRoot: URL?
    let source: Source
}
