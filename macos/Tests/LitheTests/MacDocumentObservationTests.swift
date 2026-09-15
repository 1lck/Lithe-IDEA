import CoreServices
import Foundation
import Testing
@testable import Lithe

struct MacDocumentObservationTests {
    private let readme = URL(fileURLWithPath: "/fixture/project/README.md")
    private let source = URL(fileURLWithPath: "/fixture/project/src/A.swift")
    private let sibling = URL(fileURLWithPath: "/fixture/project/src-extra/B.swift")

    @Test func buildOutputsAndUnrelatedDirectoriesDoNotReadOpenDocuments() {
        let router = MacDocumentEventRouter(urls: [readme, source])
        #expect(router.affectedDocuments(
            paths: ["/fixture/project/build/A.o", "/fixture/project/build", "/fixture/project"],
            eventFlags: [UInt32(kFSEventStreamEventFlagItemModified),
                         UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir),
                         UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsDir)]
        ).isEmpty)
    }

    @Test func fileModificationReplacementAndDeletionOnlySelectThatDocument() {
        let router = MacDocumentEventRouter(urls: [readme, source])
        #expect(router.affectedDocuments(
            paths: [source.path, source.path, source.path],
            eventFlags: [UInt32(kFSEventStreamEventFlagItemModified),
                         UInt32(kFSEventStreamEventFlagItemRenamed),
                         UInt32(kFSEventStreamEventFlagItemRemoved)]
        ) == [source])
    }

    @Test func parentReplacementOnlySelectsItsDescendants() {
        let router = MacDocumentEventRouter(urls: [readme, source, sibling])
        #expect(router.affectedDocuments(
            paths: [source.deletingLastPathComponent().path],
            eventFlags: [UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsDir)]
        ) == [source])
    }

    @Test(arguments: [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
                      kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagEventIdsWrapped,
                      kFSEventStreamEventFlagRootChanged])
    func lostEventsAndChangedRootsReconcileAllDocuments(flag: Int) {
        let documents = [readme, source, sibling]
        let router = MacDocumentEventRouter(urls: documents)
        #expect(router.affectedDocuments(paths: ["/fixture/project"], eventFlags: [UInt32(flag)]) == documents)
    }
}
