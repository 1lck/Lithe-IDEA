import Foundation
import Testing
import WebKit
@testable import Lithe

/// A scheme task that only exists to have an identity; nothing is ever delivered to it.
private final class StubSchemeTask: NSObject, WKURLSchemeTask {
    let request = URLRequest(url: URL(fileURLWithPath: "/"))
    func didReceive(_ response: URLResponse) {}
    func didReceive(_ data: Data) {}
    func didFinish() {}
    func didFailWithError(_ error: any Error) {}
    func didPerformRedirection(_ response: HTTPURLResponse, newRequest request: URLRequest) {}
}

struct LocalFileSchemeSupportTests {
    @Test func aTaskCanBeClaimedOnceAndNeverAfterItWasStopped() {
        let tasks = LocalFileSchemeTasks()
        let answered = StubSchemeTask()
        let stopped = StubSchemeTask()

        let answeredID = tasks.register(answered)
        let stoppedID = tasks.register(stopped)
        tasks.stop(stopped)

        #expect(tasks.claim(answeredID))
        #expect(!tasks.claim(answeredID), "A task is answered once")
        #expect(!tasks.claim(stoppedID), "A stopped task must not be touched again")
    }

    @Test func containmentComparesWholePathComponents() {
        let root = URL(fileURLWithPath: "/work/site")
        #expect(LocalFileContainment.contains(root, URL(fileURLWithPath: "/work/site")))
        #expect(LocalFileContainment.contains(root, URL(fileURLWithPath: "/work/site/css/app.css")))
        #expect(!LocalFileContainment.contains(root, URL(fileURLWithPath: "/work/site-private/key")))
        #expect(!LocalFileContainment.contains(root, URL(fileURLWithPath: "/work")))
        #expect(LocalFileContainment.contains(URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/work")))
    }
}
