import Foundation

struct GitWorktreeActions {
    let openProject: (URL) -> Void
    let reveal: (URL) -> Void
    let copyPath: (URL) -> Void
    let chooseParentDirectory: () -> URL?
}
