import Foundation
import Testing
@testable import Lithe

struct ProjectTreeLayoutMetricsTests {
    @Test
    func treeRowsMatchIntelliJNewUILayoutMetrics() {
        #expect(LitheTheme.Metrics.projectTreeRowSpacing == 0)
        #expect(LitheTheme.Metrics.projectTreeContentVerticalInset == 4)
        #expect(LitheTheme.Metrics.projectTreeContentHorizontalInset == 12)
        #expect(LitheTheme.Metrics.projectTreeSelectionCornerRadius == 4)
        #expect(LitheTheme.Metrics.treeIconSize == 16)
    }

    @Test
    func officialFolderAssetsProvideLightAndDarkVariants() throws {
        let iconRoot = repositoryRoot
            .appendingPathComponent("macos/Resources/IDEAIcons", isDirectory: true)
        let folderAssets = [
            "nodes/folder.svg",
            "nodes/sourceRoot.svg",
            "nodes/resourcesRoot.svg",
            "nodes/excludeRoot.svg",
            "nodes/moduleJava.svg",
            "nodes/package.svg"
        ]

        for assetPath in folderAssets {
            let baseURL = iconRoot.appendingPathComponent(assetPath)
            let darkURL = iconRoot.appendingPathComponent(
                LitheIcons.darkIdeaAssetPath(for: assetPath)
            )
            let baseSVG = try String(contentsOf: baseURL, encoding: .utf8)
            let darkSVG = try String(contentsOf: darkURL, encoding: .utf8)

            #expect(baseSVG.contains("viewBox=\"0 0 16 16\""))
            #expect(darkSVG.contains("viewBox=\"0 0 16 16\""))
            #expect(baseSVG.contains("JetBrains"))
            #expect(darkSVG.contains("JetBrains"))
        }
    }

    @Test
    func directoryMarksUseTheirMatchingFolderIcons() {
        #expect(LitheIcons.kind(for: .plain) == .folder)
        #expect(LitheIcons.kind(for: .sources) == .sourceFolder)
        #expect(LitheIcons.kind(for: .resources) == .resourceFolder)
        #expect(LitheIcons.kind(for: .excluded) == .excludedFolder)
        #expect(LitheIcons.kind(for: .module) == .moduleFolder)
        #expect(LitheIcons.kind(for: .package) == .packageFolder)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
