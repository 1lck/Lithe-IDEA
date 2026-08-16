import AppKit
import CoreText
import Foundation

enum MacBundledFontRegistry {
    private static let fonts = [
        (resource: "JetBrainsMono-Regular", postScriptName: "JetBrainsMono-Regular"),
        (resource: "JetBrainsMono-Italic", postScriptName: "JetBrainsMono-Italic"),
        (resource: "JetBrainsMono-Bold", postScriptName: "JetBrainsMono-Bold"),
        (resource: "JetBrainsMono-BoldItalic", postScriptName: "JetBrainsMono-BoldItalic")
    ]

    static func registerFonts(bundle: Bundle = .main) {
        guard bundle.url(forResource: "JetBrainsMono-Regular", withExtension: "ttf", subdirectory: "Fonts") != nil else {
            return
        }

        for font in fonts where NSFont(name: font.postScriptName, size: 13) == nil {
            guard let url = bundle.url(
                forResource: font.resource,
                withExtension: "ttf",
                subdirectory: "Fonts"
            ) else {
                report("Missing bundled font: \(font.resource).ttf")
                continue
            }

            var registrationError: Unmanaged<CFError>?
            guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &registrationError) else {
                let detail = registrationError?.takeRetainedValue().localizedDescription
                    ?? "Unknown CoreText error"
                report("Could not register \(font.resource).ttf: \(detail)")
                continue
            }
        }
    }

    private static func report(_ message: String) {
        guard let data = ("Lithe font registration: \(message)\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
