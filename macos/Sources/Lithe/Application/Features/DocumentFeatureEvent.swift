import Foundation

/// Synchronous main-actor events from the document authority. Observers that
/// cross an async boundary must capture the document state before returning.
enum DocumentFeatureEvent {
    case opened(EditorDocument)
    case changed(EditorDocument)
    case saved(EditorDocument)
    case closed(EditorDocument)
}
