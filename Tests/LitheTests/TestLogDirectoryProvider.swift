import Foundation
@testable import Lithe

struct TestLogDirectoryProvider: LogDirectoryProviding {
    let defaultLogDirectory = URL(fileURLWithPath: "/test/default-logs", isDirectory: true)
}

extension AppSettings {
    convenience init(store: any KeyValueStore) {
        self.init(
            store: store,
            logDirectoryProvider: TestLogDirectoryProvider()
        )
    }
}
