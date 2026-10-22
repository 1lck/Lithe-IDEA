import AppKit
import SwiftUI
import LitheGitModule
import Testing
@testable import Lithe

@MainActor
@Suite("Commit action button chrome", .serialized)
struct CommitActionButtonStyleTests {
    @Test(arguments: [ColorScheme.dark, .light])
    func commitFormStaysInsideItsSplitPaneWhenTheFooterStacks(scheme: ColorScheme) async throws {
        MacBundledFontRegistry.registerFonts()
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        defer { feature.reset() }
        let draft = CommitDraftFeatureModel()
        let workflow = CommitWorkflowCoordinator(draft: draft, activateGit: { nil }, workspaceGeneration: { 0 },
            generate: { _ in "" }, notify: { _ in })
        let pane = NSView()
        let host = NSHostingView(rootView: LitheSplitPaneView(axis: .vertical, placement: .trailing,
            defaultSize: LitheTheme.Commit.areaMinimumHeight,
            minimum: LitheTheme.Commit.areaMinimumHeight, maximum: 400,
            sized: {
                CommitAreaView(feature: feature, draft: draft, commitWorkflow: workflow,
                               hasBackgroundImage: false, showSettings: { _ in })
                    .background(CommitPaneBoundsProbe(view: pane))
            }, flexible: { Color.clear })
            .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "en")))
        // Keep the actual splitter constrained by its viewport, as in ChangesSidebarView.
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        for width: CGFloat in [420, 260, 420] {
            host.setFrameSize(NSSize(width: width, height: 400))
            host.layoutSubtreeIfNeeded()
            let bounds = pane.convert(pane.bounds, to: host)
            #expect(abs(bounds.height - LitheTheme.Commit.areaMinimumHeight) < 0.5)
            var buttons: [NSRect] = []
            for identifier in ["git-commit-ai", "git-commit-submit", "git-commit-and-push", "git-commit-settings"] {
                let frame = try await AgentNativeControlTestSupport.frame(of: identifier, in: host)
                #expect(frame.minY >= bounds.minY - 0.5 && frame.maxY <= bounds.maxY + 0.5,
                        "\(identifier) must stay inside the allocated commit pane")
                if identifier == "git-commit-submit" || identifier == "git-commit-and-push" {
                    #expect(frame.minX >= bounds.minX && frame.maxX <= bounds.maxX)
                    #expect(abs(frame.height - 28) < 0.5)
                    buttons.append(frame)
                }
            }
            #expect(!buttons[0].intersects(buttons[1]))
            if width == 260 {
                #expect(abs(buttons[0].midY - buttons[1].midY) >= 33.5, "Narrow commit actions must stack")
            } else {
                #expect(abs(buttons[0].midY - buttons[1].midY) < 0.5)
            }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let editor = try #require(descendants(host).compactMap { $0 as? CommitMessageTextView }.first)
            let scroll = try #require(editor.enclosingScrollView)
            let editorFrame = scroll.convert(scroll.bounds, to: host)
            #expect(editorFrame.height >= 49.5, "Stacking must not shrink the message editor")
            #expect(editorFrame.minY >= bounds.minY && editorFrame.maxY <= bounds.maxY)
            #expect(buttons.allSatisfy { !$0.intersects(editorFrame) })
        }
    }

    @Test
    func narrowActionRowsStackWithoutChangingButtonGeometry() throws {
        @ViewBuilder func actions() -> some View {
            Button {} label: { Color.clear.frame(width: 10, height: 12) }
                .buttonStyle(LitheActionButtonStyle())
            Button {} label: { Color.clear.frame(width: 10, height: 12) }
                .buttonStyle(LitheActionButtonStyle(isPrimary: true))
        }
        let renderer = ImageRenderer(content: ViewThatFits(in: .horizontal) {
            HStack(spacing: LitheTheme.ActionButton.spacing) { actions() }
            VStack(spacing: LitheTheme.ActionButton.spacing) { actions() }
        }.frame(width: 100))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == 200)
        #expect(image.height == 124) // 28 + 6 + 28; buttons retain their full geometry.
    }

    @Test
    func adjacentActionsUseSixPointGapsWithoutExternalFocusInsets() throws {
        let renderer = ImageRenderer(content: HStack(spacing: LitheTheme.ActionButton.spacing) {
            Button {} label: { Color.clear.frame(width: 10, height: 12) }
                .buttonStyle(LitheActionButtonStyle())
            Button {} label: { Color.clear.frame(width: 10, height: 12) }
                .buttonStyle(LitheActionButtonStyle(isPrimary: true))
        })
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == 300) // 72 + 6 + 72, including both painted edges.
        #expect(image.height == 56)
    }

    @Test(arguments: [CGFloat(10), CGFloat(120), CGFloat(600)])
    func actionsKeepMinimumAndUncappedContentWidths(contentWidth: CGFloat) throws {
        // Short labels keep the minimum; long labels grow without a per-page maximum.
        let renderer = ImageRenderer(content: Button {} label: {
            Color.clear.frame(width: contentWidth, height: 12)
        }
        .buttonStyle(LitheActionButtonStyle()))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == Int(max(72, contentWidth + 28) * 2))
        #expect(image.height == 56)
    }

    @Test(arguments: [ColorScheme.dark, .light], [
        (primary: false, enabled: false), (primary: false, enabled: true),
        (primary: true, enabled: false), (primary: true, enabled: true)
    ])
    func buttonsUseWelcomeGeometryAndEnabledAndDisabledColors(
        scheme: ColorScheme, state: (primary: Bool, enabled: Bool)
    ) throws {
        let (primary, enabled) = state
        let renderer = ImageRenderer(content: Button {} label: {
            Color.clear.frame(width: 10, height: 12)
        }
        .buttonStyle(LitheActionButtonStyle(isPrimary: primary))
        .disabled(!enabled)
        .environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == 144) // 72pt, with no invisible focus-ring padding.
        #expect(image.height == 56) // 28pt, matching Welcome in every form.
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        func pixel(_ x: Int, _ y: Int) -> ArraySlice<UInt8> {
            let offset = (y * image.width + x) * 4
            return pixels[offset..<(offset + 4)]
        }
        #expect(pixel(0, 0).last! < 25) // 4pt rounded corner, not a square.
        let border: UInt32 = enabled ? (primary ? 0x2D62CC : (scheme == .dark ? 0x40434A : 0xD1D3D9))
                                    : (scheme == .dark ? 0x33353B : 0xDDDFE4)
        let expected = [UInt8((border >> 16) & 255), UInt8((border >> 8) & 255), UInt8(border & 255), 255]
        #expect(zip(pixel(0, 28), expected).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
        if enabled && primary {
            #expect(zip(pixel(24, 28), [0x2D, 0x62, 0xCC, 255]).allSatisfy { abs(Int($0) - $1) <= 2 })
        } else if enabled && scheme == .light {
            #expect(pixel(24, 28).allSatisfy { $0 == 255 })
        } else {
            #expect(pixel(24, 28).last == 0)
        }
    }
}

/// Observe the bounds the production split container actually assigns to CommitAreaView.
private struct CommitPaneBoundsProbe: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
