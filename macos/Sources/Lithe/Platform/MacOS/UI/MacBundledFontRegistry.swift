import AppKit
import CoreText
import Foundation

enum MacBundledFontRegistry {
    private static let fonts = ["Thin", "ExtraLight", "Light", "Regular", "Medium", "SemiBold", "Bold", "ExtraBold"]
        .flatMap { face in
            let italic = face == "Regular" ? "Italic" : "\(face)Italic"
            return ["JetBrainsMono-\(face)", "JetBrainsMono-\(italic)"]
        }

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
            let fileExtension = "ttf"
            guard let url = bundle.url(
                forResource: font,
                withExtension: fileExtension,
                subdirectory: "Fonts"
            ) else {
                reporter("Lithe font registration: Missing bundled font: \(font).\(fileExtension)\n")
                continue
            }

            var registrationError: Unmanaged<CFError>?
            guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &registrationError) else {
                let error = registrationError?.takeRetainedValue()
                if let error, CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue { continue }
                let detail = error?.localizedDescription ?? "Unknown CoreText error"
                reporter("Lithe font registration: Could not register \(font).\(fileExtension): \(detail)\n")
                continue
            }
        }
    }

    private static func report(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
