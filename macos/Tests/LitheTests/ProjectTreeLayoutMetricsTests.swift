import Foundation
import Testing
@testable import Lithe

struct ProjectTreeLayoutMetricsTests {
    @Test
    func treeRowsMatchIntelliJNewUILayoutMetrics() {
        #expect(LitheTheme.Metrics.projectTreeRowSpacing == 1)
        #expect(LitheTheme.Metrics.projectTreeContentVerticalInset == 4)
        #expect(LitheTheme.Metrics.projectTreeContentHorizontalInset == 12)
        #expect(LitheTheme.Metrics.projectTreeSelectionCornerRadius == 4)
        #expect(LitheTheme.Metrics.treeIconSize == 16)
    }

    @Test
    func lightFolderAssetsKeepTheDarkFolderGeometry() throws {
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
            let lightURL = iconRoot.appendingPathComponent(
                LitheIcons.lightIdeaAssetPath(for: assetPath)
            )
            let baseSVG = try String(contentsOf: baseURL, encoding: .utf8)
            let lightSVG = try String(contentsOf: lightURL, encoding: .utf8)

            #expect(svgGeometry(in: baseSVG) == svgGeometry(in: lightSVG))
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

    private func svgGeometry(in source: String) -> String {
        source
            .replacingOccurrences(
                of: ##"(fill|stroke)="#[0-9A-Fa-f]{6}""##,
                with: "$1=\"#COLOR\"",
                options: .regularExpression
            )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
