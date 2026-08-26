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
