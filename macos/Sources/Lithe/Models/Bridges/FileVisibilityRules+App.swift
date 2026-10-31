import LitheCoreContracts
import LitheLocalHistoryModule
import LitheSearchModule

typealias FileVisibilityRules = LitheCoreContracts.FileVisibilityRules

extension FileVisibilityRules {
    init(searchRules: SearchVisibilityRules) {
        self.init(
            hiddenDirectoryNames: searchRules.hiddenDirectoryNames,
            hiddenFilePatterns: searchRules.hiddenFilePatterns
        )
    }

    var searchRules: SearchVisibilityRules {
        SearchVisibilityRules(
            hiddenDirectoryNames: hiddenDirectoryNames,
            hiddenFilePatterns: hiddenFilePatterns
        )
    }

    var localHistoryRules: LocalHistoryVisibilityRules {
        LocalHistoryVisibilityRules(
            hiddenDirectoryNames: hiddenDirectoryNames,
            hiddenFilePatterns: hiddenFilePatterns
        )
    }
}

extension AppSettings {
    /// Project visibility plus the rules that only keep files out of local history.
    var localHistoryRules: LocalHistoryVisibilityRules {
        let visibility = fileVisibilityRules
        return LocalHistoryVisibilityRules(
            hiddenDirectoryNames: visibility.hiddenDirectoryNames,
            hiddenFilePatterns: visibility.hiddenFilePatterns,
            ignorePatterns: localHistoryIgnorePatterns,
            ignoreRegexes: localHistoryIgnoreRegexes
        )
    }
}
