import Foundation
import os

/// The built-in hidden-path lists, exactly as Rust Core defines them.
package struct FileVisibilityDefaults: Sendable, Equatable {
    package let hiddenDirectoryNames: [String]
    package let hiddenFilePatterns: [String]
    /// The built-ins written as Hidden paths patterns, for display.
    package let builtInPatterns: [String]
    /// The project configuration folder, hidden from the tree but still watched.
    package let configurationDirectory: String
    package let configurationPattern: String

    package init(
        hiddenDirectoryNames: [String],
        hiddenFilePatterns: [String],
        builtInPatterns: [String],
        configurationDirectory: String,
        configurationPattern: String
    ) {
        self.hiddenDirectoryNames = hiddenDirectoryNames
        self.hiddenFilePatterns = hiddenFilePatterns
        self.builtInPatterns = builtInPatterns
        self.configurationDirectory = configurationDirectory
        self.configurationPattern = configurationPattern
    }
}

/// One workspace-relative path to classify. `isDirectory` is nil when the caller does not know.
package struct FileVisibilityQuery: Sendable, Equatable {
    package let relativePath: String
    package let isDirectory: Bool?

    package init(relativePath: String, isDirectory: Bool?) {
        self.relativePath = relativePath
        self.isDirectory = isDirectory
    }
}

/// Core's answer for one path.
package struct FileVisibilityVerdict: Sendable, Equatable {
    /// The tree, search and Local History leave the path out.
    package let hidden: Bool
    /// The path is hidden, yet its file events must still be delivered.
    package let watchedDespiteHiding: Bool

    package init(hidden: Bool, watchedDespiteHiding: Bool) {
        self.hidden = hidden
        self.watchedDespiteHiding = watchedDespiteHiding
    }
}

/// Evaluates hidden-path rules. The only implementation calls Rust Core's
/// `workspace.classifyVisibility` and `workspace.visibilityDefaults`; this module does not link
/// the Rust bridge, so the app injects the implementation.
///
/// Note: .agents/notes/implemented/architecture/2026-11-05-core-rules-wasm-sync-bridge.md
package protocol FileVisibilityEngine: Sendable {
    func defaults() -> FileVisibilityDefaults
    /// Classifies every query against one rule set. `hiddenDirectoryNames` and
    /// `hiddenFilePatterns` are the user's entries; Core adds the built-ins.
    func classify(
        _ queries: [FileVisibilityQuery],
        hiddenDirectoryNames: [String],
        hiddenFilePatterns: [String]
    ) -> [FileVisibilityVerdict]
}

/// Holds the installed engine.
///
/// The app target registers a Rust-backed engine as the Objective-C class
/// `LitheRustFileVisibilityEngine`, which is found by name the first time rules are evaluated.
/// Discovery by name means app code and every test host that links the app resolve it without an
/// ordering requirement. `install(_:)` replaces it, for example with a test double.
package enum FileVisibilityEngines {
    private struct State {
        var engine: (any FileVisibilityEngine)?
        var defaults: FileVisibilityDefaults?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    package static func install(_ engine: any FileVisibilityEngine) {
        state.withLock { $0 = State(engine: engine, defaults: nil) }
    }

    package static var current: any FileVisibilityEngine {
        if let engine = state.withLock({ $0.engine }) { return engine }
        guard let type = NSClassFromString("LitheRustFileVisibilityEngine") as? NSObject.Type,
              let discovered = type.init() as? any FileVisibilityEngine else {
            // There is no second implementation to fall back to.
            fatalError("No FileVisibilityEngine is installed; the app must link Rust Core.")
        }
        return state.withLock { state in
            if let engine = state.engine { return engine }
            state.engine = discovered
            return discovered
        }
    }

    /// The built-in lists, fetched from Core once per installed engine.
    package static var defaults: FileVisibilityDefaults {
        if let cached = state.withLock({ $0.defaults }) { return cached }
        let fetched = current.defaults()
        return state.withLock { state in
            if let cached = state.defaults { return cached }
            state.defaults = fetched
            return fetched
        }
    }
}
