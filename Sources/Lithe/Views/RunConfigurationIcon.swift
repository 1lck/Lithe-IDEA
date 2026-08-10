import SwiftUI

/// Presents the ecosystem behind a run configuration instead of using one
/// generic process symbol for every language. The imported SVG catalog keeps
/// these marks crisp in compact IDE rows and preserves their recognizable
/// brand colors in both light and dark appearances.
struct RunConfigurationIcon: View {
    let kind: RunConfigurationKind
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let iconKind = Self.iconKind(for: kind) {
                LitheIcon(kind: iconKind, size: size)
            } else {
                Image(systemName: kind.systemImage)
                    .font(.system(size: size * 0.82, weight: .medium))
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    static func iconKind(for kind: RunConfigurationKind) -> LitheIconKind? {
        switch kind {
        case .currentFile:
            return .plainText
        case .springBoot, .javaMain:
            return .javaGeneric
        case .mavenModule:
            return .maven
        case .process(let provider):
            switch provider.split(separator: ".").first.map(String.init) {
            case "npm", "node", "bun", "deno":
                return .javaScript
            case "compose", "docker":
                return .docker
            case "python":
                return .pythonSource
            case "go":
                return .goSource
            case "cargo", "rust":
                return .rustSource
            case "maven":
                return .maven
            case "gradle":
                return .gradle
            case "java":
                return .javaGeneric
            case "kotlin":
                return .kotlinSource
            case "swift":
                return .swiftSource
            case "ruby", "rails":
                return .rubySource
            case "php", "composer":
                return .phpSource
            case "scala", "sbt":
                return .scalaSource
            case "groovy":
                return .groovySource
            case "c":
                return .cSource
            case "cpp", "cmake":
                return .cppSource
            case "csharp", "dotnet":
                return .csharpSource
            case "make", "just", "procfile":
                return .scriptSource
            default:
                return nil
            }
        }
    }
}
