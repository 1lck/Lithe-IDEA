import Foundation
import LitheGitModule

struct GitWorktreeActions {
    let openProject: (URL) -> Void
    let reveal: (URL) -> Void
    let copyPath: (URL) -> Void
    let chooseParentDirectory: () -> URL?
    var openProjectInCurrentWindow: ((URL) -> Void)? = nil
    var openProjectInNewWindow: ((URL) -> Void)? = nil
    var temporaryDirectory: (() -> URL)? = nil
    var showChange: ((GitChange) -> Void)? = nil
    var openFile: ((URL, String) -> Void)? = nil
}
