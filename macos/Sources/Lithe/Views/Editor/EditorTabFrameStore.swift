import CoreGraphics

/// Where each editor tab currently sits, recorded from layout.
///
/// Deliberately a reference box held as `@State` rather than `@State` storage of
/// the dictionary itself. The frames are only read when a drag or drop begins,
/// but the preference that reports them fires on *every* layout pass — including
/// every frame of a pane resize. Storing them as view state made each of those
/// passes re-evaluate the whole editor area; a reference box records them
/// without invalidating anything.
///
/// Follows the same pattern as `EditorViewportStore` and `LithePointerCursor`.
@MainActor
final class EditorTabFrameStore {
    private(set) var frames: [EditorTabItem: CGRect] = [:]

    func update(_ frames: [EditorTabItem: CGRect]) {
        self.frames = frames
    }

    subscript(item: EditorTabItem) -> CGRect? {
        frames[item]
    }
}
