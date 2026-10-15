import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
struct DatabaseToolbarAppearanceTests {
    @Test(arguments: [false, true])
    func disabledToolbarLabelsRespectNativeAndInheritedState(dark: Bool) throws {
        let button = Button {} label: { Color.red.frame(width: 16, height: 16) }
        let variants = [
            AnyView(button.litheToolbarIconButton(isEnabled: false)),
            AnyView(button.litheToolbarIconButton().disabled(true)),
            AnyView(HStack(spacing: 0) { button.litheToolbarIconButton() }.disabled(true))
        ]
        for variant in variants {
            let rendered = try #require(ImageRenderer(content: variant
                .environment(\.colorScheme, dark ? .dark : .light)).cgImage)
            #expect(rendered.width == 22 && rendered.height == 22)
            let color = try #require(NSBitmapImageRep(cgImage: rendered).colorAt(x: 11, y: 11))
            // All disabling routes dim once, including the enclosing toolbar group.
            #expect(color.alphaComponent > 0.4 && color.alphaComponent < 0.5)
        }
        let textButton = Button {} label: { Color.red.frame(width: 44, height: 16) }
            .litheToolbarIconButton(isIconOnly: false)
        let rendered = try #require(ImageRenderer(content: textButton).cgImage)
        #expect(rendered.width == 44 && rendered.height == 22)
        let color = try #require(NSBitmapImageRep(cgImage: rendered).colorAt(x: 22, y: 11))
        #expect(color.alphaComponent == 1 && color.redComponent > color.greenComponent)
    }

    @Test(arguments: [false, true])
    func providerAssetsUseNativeTreeCanvas(dark: Bool) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/DatabaseIcons")
        for name in ["mysql", "mariadb", "postgres", "sqlite", "sqlserver", "mongodb", "redis"] {
            let filename = name + (dark && name != "mongodb" ? "_dark" : "") + ".svg"
            let image = try #require(NSImage(contentsOf: root.appendingPathComponent(filename)))
            #expect(image.size == NSSize(width: 16, height: 16))
            let rendered = try #require(ImageRenderer(content: Image(nsImage: image)).cgImage)
            let pixels = NSBitmapImageRep(cgImage: rendered)
            var bounds = CGRect.null
            for y in 0..<pixels.pixelsHigh {
                for x in 0..<pixels.pixelsWide where (pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                    bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            #expect(max(bounds.width, bounds.height) >= 12)
        }
    }

    @Test(arguments: [false, true])
    func toolbarResourcesKeepNativeSizeAndSharedButtonBounds(dark: Bool) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/IDEAIcons")
        for path in [
            "expui/general/add.svg", "expui/actions/newFolder.svg", "expui/general/import.svg",
            "expui/general/collapseAll.svg", "expui/general/refresh.svg", "expui/fileTypes/shell.svg",
            "expui/general/history.svg", "expui/general/previewVertically.svg", "expui/general/filter.svg", "expui/general/sortBy.svg",
            "expui/toolwindows/structure.svg", "expui/actions/checked.svg", "expui/general/undo.svg", "expui/general/moreHorizontal.svg", "expui/general/previewVertically.svg",
            "expui/general/upload.svg", "expui/general/reset.svg", "expui/general/chevronDown.svg", "expui/general/chevronLeft.svg", "expui/general/chevronRight.svg",
            "general/arrowSplitCenterV.svg", "general/arrowUp.svg", "general/arrowDown.svg",
            "expui/general/delete.svg", "expui/general/edit.svg", "expui/status/warning.svg", "expui/nodes/dataTables.svg",
            "expui/general/greenCheckmark.svg", "expui/status/error.svg",
            "database/expui/goldKey.svg", "database/expui/blueKey.svg", "database/expui/collection.svg",
            "database/expui/schema.svg", "database/expui/objectGroup.svg", "database/expui/table.svg", "database/expui/column.svg"
        ] {
            let asset = dark ? LitheIcons.darkIdeaAssetPath(for: path) : path
            let image = try #require(NSImage(contentsOf: root.appendingPathComponent(asset)))
            #expect(image.size == NSSize(width: 16, height: 16))
            let renderer = ImageRenderer(content: Button {} label: {
                Image(nsImage: image)
            }.litheToolbarIconButton().environment(\.colorScheme, dark ? .dark : .light))
            let rendered = try #require(renderer.cgImage)
            #expect(rendered.width == 22)
            #expect(rendered.height == 22)
        }
    }
}
