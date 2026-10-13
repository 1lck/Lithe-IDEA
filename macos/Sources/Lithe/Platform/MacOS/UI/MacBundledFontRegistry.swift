import AppKit
import CoreText
import Foundation

enum MacBundledFontRegistry {
    private static let fonts = ["Thin", "ExtraLight", "Light", "Regular", "Medium", "SemiBold", "Bold", "ExtraBold"]
        .flatMap { face in
            let italic = face == "Regular" ? "Italic" : "\(face)Italic"
            return ["JetBrainsMono-\(face).ttf", "JetBrainsMono-\(italic).ttf"]
        } + ["Thin", "ExtraLight", "Light", "Regular", "Medium", "SemiBold", "Bold", "ExtraBold", "Black"]
        .flatMap { face in
            let italic = face == "Regular" ? "Italic" : "\(face)Italic"
            return ["Inter-\(face).otf", "Inter-\(italic).otf"]
        } + ["Regular", "Bold", "Italic", "BoldItalic"].map { "JetBrainsMonoNerdFontMono-\($0).ttf" }

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

        for font in fonts {
            guard let url = bundle.url(forResource: font, withExtension: nil, subdirectory: "Fonts") else {
                reporter("Lithe font registration: Missing bundled font: \(font)\n")
                continue
            }

            var registrationError: Unmanaged<CFError>?
            guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &registrationError) else {
                let error = registrationError?.takeRetainedValue()
                if let error, CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue { continue }
                let detail = error?.localizedDescription ?? "Unknown CoreText error"
                reporter("Lithe font registration: Could not register \(font): \(detail)\n")
                continue
            }
        }
    }

    private static func report(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
