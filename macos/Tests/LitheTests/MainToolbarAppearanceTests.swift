import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite(.serialized)
struct MainToolbarAppearanceTests {
    @Test
    func runIconResolvesTheIslandsAndParentThemeColors() throws {
        for (name, hex) in [(NSAppearance.Name.darkAqua, 0x4E9D6C), (.aqua, 0x369650)] {
            let appearance = try #require(NSAppearance(named: name))
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(LitheTheme.MainToolbar.runIcon).usingColorSpace(.sRGB)
            }
            let color = try #require(resolved)
            #expect(abs(color.redComponent - CGFloat((hex >> 16) & 255) / 255) < 0.005)
            #expect(abs(color.greenComponent - CGFloat((hex >> 8) & 255) / 255) < 0.005)
            #expect(abs(color.blueComponent - CGFloat(hex & 255) / 255) < 0.005)
        }
    }

    @Test
    func runButtonKeepsItsOuterInsetsOutsideThePaintedSurface() throws {
        for dark in [false, true] {
            for enabled in [false, true] {
                let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
                let content = Button {} label: {
                    Color.clear.frame(width: 16, height: 16)
                }
                .buttonStyle(LitheMainToolbarButtonStyle(
                    insets: LitheTheme.MainToolbar.runInsets,
                    isActive: true
                ))
                .disabled(!enabled)
                .background(dark ? Color.black : Color.white)
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: content)
                host.appearance = appearance
                #expect(host.fittingSize == NSSize(width: 34, height: 40))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                appearance.performAsCurrentDrawingAppearance {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                // Compare in the backing bitmap's native color space; converting a
                // display-profile sample to sRGB changes the numeric blend values.
                func red(_ x: Int, _ y: Int) throws -> CGFloat {
                    let sample = try #require(bitmap.colorAt(
                        x: x * bitmap.pixelsWide / 34,
                        y: y * bitmap.pixelsHigh / 40
                    ))
                    return sample.redComponent
                }
                let background: CGFloat = dark ? 0 : 1
                #expect(abs(try red(17, 2) - background) < 0.01)
                #expect(abs(try red(0, 20) - background) < 0.01)
                let center: CGFloat = !enabled ? background : (dark ? 41.0 / 255 : 1 - 32.0 / 255)
                let actual = try red(17, 20)
                #expect(abs(actual - center) < 0.01, "dark=\(dark), enabled=\(enabled), actual=\(actual), expected=\(center)")
            }
        }
    }
}
