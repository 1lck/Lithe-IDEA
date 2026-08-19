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
        registerFonts(bundle: bundle, reporter: report)
    }

    static func registerFonts(
        bundle: Bundle = .main,
        reporter: (String) -> Void
    ) {
        guard bundle.url(forResource: "JetBrainsMono-Regular", withExtension: "ttf", subdirectory: "Fonts") != nil else {
            return
        }

        for font in fonts where NSFont(name: font.postScriptName, size: 13) == nil {
            guard let url = bundle.url(
                forResource: font.resource,
                withExtension: "ttf",
                subdirectory: "Fonts"
            ) else {
                reporter("Lithe font registration: Missing bundled font: \(font.resource).ttf\n")
                continue
            }

            var registrationError: Unmanaged<CFError>?
            guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &registrationError) else {
                let detail = registrationError?.takeRetainedValue().localizedDescription
                    ?? "Unknown CoreText error"
                reporter("Lithe font registration: Could not register \(font.resource).ttf: \(detail)\n")
                continue
            }
        }
    }

    private static func report(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
