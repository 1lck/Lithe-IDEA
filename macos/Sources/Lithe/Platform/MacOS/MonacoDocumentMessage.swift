/// Closed-document tooling and view notifications are stale work, but an
/// unacknowledged text edit or save must retain the editor's failure protection.
enum MonacoDocumentMessage {
    static func replyToClosedDocument(type: String, reply: (Any?, String?) -> Void) {
        if type == "edit" || type == "save" {
            reply(nil, "Document closed")
        } else {
            reply(["cancelled": true], nil)
        }
    }
}
