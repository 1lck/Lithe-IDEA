import LitheModuleAPI
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

    static func registerFonts(
        bundle: Bundle = .main,
        logSink: (any LogSink)? = nil
    ) {
        guard bundle.url(forResource: "JetBrainsMono-Regular", withExtension: "ttf", subdirectory: "Fonts") != nil else {
            return
        }

        for font in fonts {
            guard let url = bundle.url(forResource: font, withExtension: nil, subdirectory: "Fonts") else {
                logSink?.emit(AppFontMissing(font: font))
                continue
            }

            var registrationError: Unmanaged<CFError>?
            guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &registrationError) else {
                let error = registrationError?.takeRetainedValue()
                if let error, CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue { continue }
                logSink?.emit(AppFontRegistrationFailed(error: error.map { $0 as Error } ?? NSError(domain: "CoreText", code: -1), font: font))
                continue
            }
        }
    }

}
