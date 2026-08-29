import Foundation
import LitheCoreContracts
import LitheDebugModule
@testable import Lithe
import Testing

struct DebugBreakpointPersistenceTests {
    @Test
    func macStoreKeepsBreakpointSnapshotsSeparateByProject() throws {
        let preferences = DebugBreakpointTestStore()
        let store = MacDebugBreakpointStore(store: preferences)
        let firstRoot = URL(fileURLWithPath: "/tmp/first-debug-project", isDirectory: true)
        let secondRoot = URL(fileURLWithPath: "/tmp/second-debug-project", isDirectory: true)
        let first = DebugBreakpointSnapshot(
            areBreakpointsMuted: true,
            breakpoints: [PersistedDebugBreakpoint(
                relativePath: "src/Main.java",
                line: 12,
                enabled: false,
                condition: "user != null",
                hitCondition: "2",
                logMessage: "user = {user}"
            )]
        )
        let second = DebugBreakpointSnapshot(
            breakpoints: [PersistedDebugBreakpoint(relativePath: "App.java", line: 4)]
        )

        try store.saveBreakpoints(first, for: firstRoot)
        try store.saveBreakpoints(second, for: secondRoot)

        #expect(try store.loadBreakpoints(for: firstRoot) == first)
        #expect(try store.loadBreakpoints(for: secondRoot) == second)
        let firstData = try #require(preferences.data(
            forKey: "lithe.debug.breakpoints." + firstRoot.path
        ))
        #expect(!String(decoding: firstData, as: UTF8.self).contains(firstRoot.path))
        #expect(try store.loadBreakpoints(
            for: URL(fileURLWithPath: "/tmp/unknown-debug-project", isDirectory: true)
        ) == nil)
    }

    @Test
    func macStoreReportsCorruptBreakpointData() {
        let preferences = DebugBreakpointTestStore()
        let root = URL(fileURLWithPath: "/tmp/corrupt-debug-project", isDirectory: true)
        preferences.set(Data("not-json".utf8), forKey: "lithe.debug.breakpoints." + root.path)
        let store = MacDebugBreakpointStore(store: preferences)

        #expect(throws: MacDebugBreakpointStoreError.self) {
            try store.loadBreakpoints(for: root)
        }
    }

    @Test
    func macStorePersistsSteppingFiltersByAdapter() throws {
        let preferences = DebugBreakpointTestStore()
        let store = MacDebugSteppingFilterStore(store: preferences)
        let java = DebugSteppingFilters(
            classNameFilters: ["$JDK", "org.mockito.*"],
            skipSynthetics: true,
            skipStaticInitializers: true,
            skipConstructors: false,
            hideFilteredStackFrames: true
        )
        let go = DebugSteppingFilters(
            classNameFilters: [],
            skipSynthetics: false,
            skipStaticInitializers: false,
            skipConstructors: false,
            hideFilteredStackFrames: false
        )

        try store.saveSteppingFilters(java, adapterID: "java")
        try store.saveSteppingFilters(go, adapterID: "go")

        #expect(try store.loadSteppingFilters(adapterID: "java") == java)
        #expect(try store.loadSteppingFilters(adapterID: "go") == go)
        #expect(try store.loadSteppingFilters(adapterID: "python") == nil)
    }

    @Test
    func macStoreReportsCorruptSteppingFilterData() {
        let preferences = DebugBreakpointTestStore()
        preferences.set(Data("not-json".utf8), forKey: "lithe.debug.steppingFilters.java")
        let store = MacDebugSteppingFilterStore(store: preferences)

        #expect(throws: MacDebugSteppingFilterStoreError.self) {
            try store.loadSteppingFilters(adapterID: "java")
        }
    }
}

private final class DebugBreakpointTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
