import AppKit
import SwiftUI

/// 项目树、标签页、面包屑和 Search Everywhere 共用的图标分类。
/// 这里是唯一的文件图标分类入口，避免视图层重复判断文件类型。
enum LitheIconKind: Hashable {
    // Java 符号
    case javaClass
    case javaInterface
    case javaEnum
    case javaRecord
    case javaAnnotation
    case javaGeneric

    // 其他语言
    case swiftSource
    case kotlinSource
    case rustSource
    case goSource
    case pythonSource
    case rubySource
    case scalaSource
    case groovySource
    case phpSource
    case cSource
    case cHeader
    case cppSource
    case csharpSource
    case scriptSource
    case javaScript
    case css
    case html

    // 配置与数据
    case maven
    case gradle
    case xml
    case properties
    case editorConfig
    case yaml
    case json
    case toml
    case csv
    case docker
    case database
    case gitignore

    // 文本与媒体
    case markdown
    case plainText
    case image
    case binary
    case generic

    // 目录
    case folder
    case sourceFolder
    case resourceFolder
    case excludedFolder
    case moduleFolder
    case packageFolder
}

enum LitheIcons {
    // MARK: - 分类

    /// Reused IntelliJ Platform assets. The custom SwiftUI drawings below remain
    /// the fallback for file kinds that are not covered by the imported set.
    private static let ideaAssetPaths: [LitheIconKind: String] = [
        .javaClass: "nodes/class.svg",
        .javaInterface: "nodes/interface.svg",
        .javaEnum: "nodes/enum.svg",
        .javaRecord: "nodes/record.svg",
        .javaAnnotation: "nodes/annotation.svg",
        .javaGeneric: "fileTypes/java.svg",
        .swiftSource: "fileTypes/swiftLang.svg",
        .kotlinSource: "fileTypes/kotlin.svg",
        .rustSource: "fileTypes/rust.svg",
        .goSource: "fileTypes/go.svg",
        .pythonSource: "fileTypes/python.svg",
        .rubySource: "fileTypes/ruby.svg",
        .scalaSource: "fileTypes/scala.svg",
        .groovySource: "fileTypes/groovy.svg",
        .phpSource: "fileTypes/php.svg",
        .cSource: "fileTypes/c.svg",
        .cHeader: "fileTypes/h.svg",
        .cppSource: "fileTypes/cpp.svg",
        .csharpSource: "fileTypes/csharp.svg",
        .scriptSource: "fileTypes/shell.svg",
        .javaScript: "fileTypes/javaScript.svg",
        .css: "fileTypes/css.svg",
        .html: "fileTypes/html.svg",
        .maven: "maven/mavenProject.svg",
        .gradle: "fileTypes/gradle.svg",
        .xml: "fileTypes/xml.svg",
        .properties: "fileTypes/properties.svg",
        .editorConfig: "fileTypes/editorConfig.svg",
        .yaml: "fileTypes/yaml.svg",
        .json: "fileTypes/json.svg",
        .toml: "fileTypes/toml.svg",
        .csv: "fileTypes/csv.svg",
        .docker: "fileTypes/docker.svg",
        .database: "fileTypes/sql.svg",
        .markdown: "fileTypes/markdown.svg",
        .plainText: "fileTypes/text.svg",
        .image: "fileTypes/image.svg",
        .binary: "fileTypes/archive.svg",
        .generic: "fileTypes/unknown.svg",
        .folder: "nodes/folder.svg",
        .sourceFolder: "nodes/sourceRoot.svg",
        .resourceFolder: "nodes/resourcesRoot.svg",
        .excludedFolder: "nodes/excludeRoot.svg",
        .moduleFolder: "nodes/moduleJava.svg",
        .packageFolder: "nodes/package.svg"
    ]

    /// Common SF Symbol names used by Lithe that have a direct IntelliJ
    /// Platform equivalent. Unmapped symbols intentionally keep their native
    /// fallback because IntelliJ has no meaningful one-to-one asset for them.
    private static let ideaAssetPathsBySystemImage: [String: String] = [
        "magnifyingglass": "actions/search.svg",
        "arrow.clockwise": "actions/refresh.svg",
        "gearshape": "general/gear.svg",
        "gearshape.fill": "general/gear.svg",
        "folder": "nodes/folder.svg",
        "doc.text": "fileTypes/text.svg",
        "play.fill": "actions/execute.svg",
        "play.rectangle": "actions/execute.svg",
        "point.3.connected.trianglepath.dotted": "toolwindows/toolWindowVcs.svg",
        "shippingbox": "maven/toolWindowMaven.svg",
        "ladybug": "toolwindows/toolWindowDebugger.svg",
        "exclamationmark.triangle": "toolwindows/toolWindowProblems.svg",
        "ellipsis": "actions/more.svg",
        "ellipsis.vertical": "actions/moreVertical.svg",
        "magnifyingglass.circle": "toolwindows/toolWindowFind.svg",
        "list.bullet.indent": "toolwindows/toolWindowStructure.svg",
        "arrow.triangle.branch": "toolwindows/toolWindowVcs.svg",
        "checkmark.circle": "vcs/commit.svg",
        "plusminus": "vcs/diff.svg"
    ]

    /// 排除目录名：这些目录在 IDEA 里显示为橙色（构建产物）。
    private static let excludedDirectoryNames: Set<String> = [
        "target", "build", "out", "bin", "dist", "node_modules", ".gradle", ".idea", ".settings"
    ]

    private static let resourceDirectoryNames: Set<String> = ["resources", "res", "webapp", "static"]
    private static let sourceDirectoryNames: Set<String> = ["java", "kotlin", "scala", "groovy"]

    static func kind(for url: URL, isDirectory: Bool, isInsideSourceRoot: Bool = false) -> LitheIconKind {
        if isDirectory { return directoryKind(for: url, isInsideSourceRoot: isInsideSourceRoot) }
        return fileKind(for: url)
    }

    static func ideaAssetPath(forSystemImage systemImage: String) -> String? {
        ideaAssetPathsBySystemImage[systemImage]
    }

    /// src/main/java、src/test/kotlin 之类的源码根。资源根同样按这个布局
    /// 判断，避免把任意一个叫 resources 的目录标成资源根。
    static func isSourceRootDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        guard sourceDirectoryNames.contains(name) || resourceDirectoryNames.contains(name) else {
            return false
        }
        let parent = url.deletingLastPathComponent().lastPathComponent.lowercased()
        return parent == "main" || parent == "test"
    }

    private static func directoryKind(for url: URL, isInsideSourceRoot: Bool) -> LitheIconKind {
        let name = url.lastPathComponent
        if excludedDirectoryNames.contains(name.lowercased()) { return .excludedFolder }

        let lowercased = name.lowercased()
        let parent = url.deletingLastPathComponent().lastPathComponent.lowercased()
        let isStandardLayoutRoot = parent == "main" || parent == "test"

        if sourceDirectoryNames.contains(lowercased), isStandardLayoutRoot {
            return .sourceFolder
        }
        if resourceDirectoryNames.contains(lowercased), isStandardLayoutRoot {
            return .resourceFolder
        }
        // 源码根之下、名字是合法包名的目录才是包。IDEA 的
        // JavaDirectoryIconProvider.isValidPackage 同样要求名字合法，
        // 所以 META-INF 这种带连字符的目录仍然是普通文件夹。
        if isInsideSourceRoot, isValidPackageName(name) { return .packageFolder }
        return .folder
    }

    /// Java 包名段：首字符是字母或下划线，其余是字母、数字或下划线。
    static func isValidPackageName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        guard CharacterSet.letters.contains(first) || first == "_" else { return false }
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
    }

    private static func fileKind(for url: URL) -> LitheIconKind {
        let name = url.lastPathComponent.lowercased()
        if name == "pom.xml" { return .maven }
        if name == ".gitignore" || name == ".gitattributes" || name == ".dockerignore" { return .gitignore }
        if name == ".classpath" || name == ".project" || name == ".factorypath" { return .xml }
        if name == ".editorconfig" { return .editorConfig }
        if name == "dockerfile" || name.hasPrefix("dockerfile.") { return .docker }
        // build.gradle.kts 是构建脚本，扩展名 kts 会被 Kotlin 抢走。
        if name.hasSuffix(".gradle.kts") { return .gradle }
        // .env.local、.env.production 的扩展名不是 env。
        if name == ".env" || name.hasPrefix(".env.") { return .properties }

        switch url.pathExtension.lowercased() {
        case "java": return .javaGeneric
        case "class", "jar": return .binary
        case "swift": return .swiftSource
        case "kt", "kts": return .kotlinSource
        case "rs": return .rustSource
        case "go": return .goSource
        case "py", "pyw", "pyi": return .pythonSource
        case "rb", "rake", "gemspec": return .rubySource
        case "scala", "sc": return .scalaSource
        case "groovy": return .groovySource
        case "php", "phtml": return .phpSource
        case "c", "m": return .cSource
        case "h", "hh", "hpp", "hxx": return .cHeader
        case "cpp", "cc", "cxx", "mm": return .cppSource
        case "cs": return .csharpSource
        case "js", "jsx", "mjs", "cjs", "ts", "tsx": return .javaScript
        case "sh", "zsh", "bash", "fish": return .scriptSource
        case "css", "scss", "sass", "less": return .css
        case "html", "htm", "xhtml", "vue", "svelte": return .html
        case "toml": return .toml
        case "gradle": return .gradle
        case "xml", "xsd", "wsdl", "pom": return .xml
        case "properties", "ini", "cfg", "conf", "env": return .properties
        case "yml", "yaml": return .yaml
        case "json", "json5": return .json
        case "db", "sqlite", "sqlite3", "sql", "mv": return .database
        case "md", "markdown", "rst", "adoc": return .markdown
        case "txt", "log": return .plainText
        case "csv", "tsv": return .csv
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp", "tiff": return .image
        case "zip", "gz", "tar", "so", "dylib", "dll", "icns", "pdf", "woff", "woff2", "ttf", "otf": return .binary
        default: return .generic
        }
    }

    /// 从 Java 源码开头判断是 class / interface / enum / record / @interface。
    /// 只看首个类型声明，读不出来就回退 .javaGeneric。
    static func javaSymbolKind(fromSourcePrefix prefix: String) -> LitheIconKind {
        let stripped = strippingCommentsAndStrings(prefix)
        let pattern = #"\b(class|interface|enum|record)\s+[A-Za-z_$]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return .javaGeneric }
        let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
        guard let match = expression.firstMatch(in: stripped, range: range),
              let keywordRange = Range(match.range(at: 1), in: stripped) else { return .javaGeneric }

        switch String(stripped[keywordRange]) {
        case "interface":
            // @interface 是注解声明，往前看一个非空字符是否为 @
            let before = stripped[stripped.startIndex..<keywordRange.lowerBound]
            if before.last(where: { !$0.isWhitespace }) == "@" { return .javaAnnotation }
            return .javaInterface
        case "enum": return .javaEnum
        case "record": return .javaRecord
        default: return .javaClass
        }
    }

    /// 粗略去掉注释和字符串，避免 "class" 出现在注释里造成误判。
    private static func strippingCommentsAndStrings(_ source: String) -> String {
        var result = ""
        let characters = Array(source)
        var index = 0
        enum State { case code, lineComment, blockComment, string, character }
        var state = State.code

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            switch state {
            case .code:
                if character == "/", next == "/" { state = .lineComment; index += 2; continue }
                if character == "/", next == "*" { state = .blockComment; index += 2; continue }
                if character == "\"" { state = .string; index += 1; continue }
                if character == "'" { state = .character; index += 1; continue }
                result.append(character)
            case .lineComment:
                if character == "\n" { state = .code; result.append(character) }
            case .blockComment:
                if character == "*", next == "/" { state = .code; index += 2; continue }
            case .string:
                if character == "\\" { index += 2; continue }
                if character == "\"" { state = .code }
            case .character:
                if character == "\\" { index += 2; continue }
                if character == "'" { state = .code }
            }
            index += 1
        }
        return result
    }

    // MARK: - 外观定义

    /// 每个 kind 归到一种画法。几何只写一次，SwiftUI 和 AppKit 共用。
    enum Appearance {
        /// 彩色圆形 + 白色字母（Java 符号，仿 IDEA 的 C/I/E/R/A 徽章）
        case letterBadge(String, Color)
        /// 文档轮廓（折角）+ 可选类型标识
        case document(accent: Color, mark: DocumentMark)
        /// 文件夹形状
        case folder(Color, hasBadge: Bool)
    }

    enum DocumentMark: Hashable {
        case none
        case letter(String)
        /// 三条横线，用于 properties / plainText
        case lines
        /// 尖括号，用于 xml
        case angleBrackets
        /// 花括号，用于 json
        case braces
        /// 山与太阳，用于图片
        case picture
        /// 三层圆柱，用于数据库
        case cylinder
    }

    static func appearance(for kind: LitheIconKind) -> Appearance {
        switch kind {
        case .javaClass: .letterBadge("C", Color(red: 0.29, green: 0.62, blue: 0.86))
        case .javaInterface: .letterBadge("I", Color(red: 0.30, green: 0.70, blue: 0.48))
        case .javaEnum: .letterBadge("E", Color(red: 0.79, green: 0.55, blue: 0.24))
        case .javaRecord: .letterBadge("R", Color(red: 0.45, green: 0.56, blue: 0.86))
        case .javaAnnotation: .letterBadge("@", Color(red: 0.79, green: 0.66, blue: 0.28))
        case .javaGeneric: .letterBadge("J", Color(red: 0.29, green: 0.62, blue: 0.86))

        case .swiftSource: .document(accent: Color(red: 0.94, green: 0.44, blue: 0.24), mark: .letter("S"))
        case .kotlinSource: .document(accent: Color(red: 0.63, green: 0.42, blue: 0.90), mark: .letter("K"))
        case .rustSource: .document(accent: Color(red: 0.78, green: 0.49, blue: 0.33), mark: .letter("R"))
        case .goSource: .document(accent: Color(red: 0.33, green: 0.54, blue: 0.97), mark: .letter("G"))
        case .pythonSource: .document(accent: Color(red: 0.95, green: 0.77, blue: 0.36), mark: .letter("P"))
        case .rubySource: .document(accent: Color(red: 0.86, green: 0.36, blue: 0.36), mark: .letter("R"))
        case .scalaSource: .document(accent: Color(red: 0.86, green: 0.36, blue: 0.36), mark: .letter("S"))
        case .groovySource: .document(accent: Color(red: 0.34, green: 0.59, blue: 0.36), mark: .letter("G"))
        case .phpSource: .document(accent: Color(red: 0.33, green: 0.54, blue: 0.97), mark: .letter("P"))
        case .cSource: .document(accent: Color(red: 0.71, green: 0.54, blue: 0.93), mark: .letter("C"))
        case .cHeader: .document(accent: Color(red: 0.78, green: 0.49, blue: 0.33), mark: .letter("h"))
        case .cppSource: .document(accent: Color(red: 0.71, green: 0.54, blue: 0.93), mark: .letter("C"))
        case .csharpSource: .document(accent: Color(red: 0.37, green: 0.68, blue: 0.40), mark: .letter("C"))
        case .scriptSource: .document(accent: Color(red: 0.85, green: 0.76, blue: 0.32), mark: .braces)
        case .javaScript: .document(accent: Color(red: 0.95, green: 0.77, blue: 0.36), mark: .letter("J"))
        case .css: .document(accent: Color(red: 0.33, green: 0.54, blue: 0.97), mark: .letter("C"))
        case .html: .document(accent: Color(red: 0.34, green: 0.59, blue: 0.36), mark: .angleBrackets)

        case .maven: .document(accent: Color(red: 0.36, green: 0.60, blue: 0.90), mark: .letter("m"))
        case .gradle: .document(accent: Color(red: 0.30, green: 0.66, blue: 0.68), mark: .letter("G"))
        case .xml: .document(accent: Color(red: 0.72, green: 0.55, blue: 0.88), mark: .angleBrackets)
        case .properties: .document(accent: Color(red: 0.60, green: 0.64, blue: 0.72), mark: .lines)
        case .editorConfig: .document(accent: Color(red: 0.60, green: 0.64, blue: 0.72), mark: .lines)
        case .yaml: .document(accent: Color(red: 0.55, green: 0.72, blue: 0.55), mark: .lines)
        case .json: .document(accent: Color(red: 0.82, green: 0.70, blue: 0.36), mark: .braces)
        case .toml: .document(accent: Color(red: 0.33, green: 0.54, blue: 0.97), mark: .lines)
        case .csv: .document(accent: Color(red: 0.34, green: 0.59, blue: 0.36), mark: .lines)
        case .docker: .document(accent: Color(red: 0.33, green: 0.54, blue: 0.97), mark: .none)
        case .database: .document(accent: Color(red: 0.52, green: 0.68, blue: 0.84), mark: .cylinder)
        case .gitignore: .document(accent: Color(red: 0.85, green: 0.44, blue: 0.32), mark: .lines)

        case .markdown: .document(accent: Color(red: 0.45, green: 0.72, blue: 0.88), mark: .letter("M"))
        case .plainText: .document(accent: Color(red: 0.58, green: 0.62, blue: 0.68), mark: .lines)
        case .image: .document(accent: Color(red: 0.48, green: 0.72, blue: 0.62), mark: .picture)
        case .binary: .document(accent: Color(red: 0.52, green: 0.55, blue: 0.60), mark: .none)
        case .generic: .document(accent: Color(red: 0.56, green: 0.60, blue: 0.66), mark: .none)

        case .folder: .folder(Color(red: 0.52, green: 0.62, blue: 0.76), hasBadge: false)
        case .sourceFolder: .folder(Color(red: 0.42, green: 0.66, blue: 0.90), hasBadge: true)
        case .resourceFolder: .folder(Color(red: 0.82, green: 0.68, blue: 0.36), hasBadge: true)
        case .excludedFolder: .folder(Color(red: 0.85, green: 0.53, blue: 0.28), hasBadge: false)
        case .moduleFolder: .folder(Color(red: 0.56, green: 0.70, blue: 0.86), hasBadge: true)
        case .packageFolder: .folder(Color(red: 0.60, green: 0.64, blue: 0.70), hasBadge: false)
        }
    }

    // MARK: - AppKit 消费入口

    /// 渲染好的图标按 kind+size 缓存，避免每次滚动都重画。
    @MainActor
    private final class ImageCache {
        static let shared = ImageCache()
        var storage: [String: NSImage] = [:]
    }

    /// Loads an imported IntelliJ SVG from the app bundle. Keeping this lookup
    /// behind the same catalog lets the sidebar, tabs and breadcrumbs reuse it.
    @MainActor
    static func ideaImage(for kind: LitheIconKind) -> NSImage? {
        guard let assetPath = ideaAssetPaths[kind] else { return nil }
        return ideaImage(resourcePath: assetPath)
    }

    /// Loads an arbitrary imported IntelliJ SVG. This is used for chrome icons
    /// (VCS, tool windows and actions) that are not file-node kinds.
    @MainActor
    static func ideaImage(resourcePath: String) -> NSImage? {
        let cacheKey = "idea:\(resourcePath)"
        if let cached = ImageCache.shared.storage[cacheKey] { return cached }

        let path = resourcePath as NSString
        let directory = path.deletingLastPathComponent
        let filename = path.lastPathComponent as NSString
        let resourceName = filename.deletingPathExtension
        guard let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: filename.pathExtension,
            subdirectory: "IDEAIcons/\(directory)"
        ), let image = NSImage(contentsOf: url) else {
            return nil
        }
        ImageCache.shared.storage[cacheKey] = image
        return image
    }

    /// gutter、OutputTextView 等 AppKit 侧使用。通过 ImageRenderer 复用
    /// SwiftUI 的几何定义，避免把每个图标画两遍。
    @MainActor
    static func nsImage(_ kind: LitheIconKind, size: CGFloat) -> NSImage? {
        render(key: "\(kind):\(size)", content: LitheIcon(kind: kind, size: size))
    }

    /// gutter 的实现/重写标记：绿色圆形 + 向下/向上箭头。
    @MainActor
    static func implementationMarkerImage(pointingDown: Bool, size: CGFloat) -> NSImage? {
        render(
            key: "impl:\(pointingDown):\(size)",
            content: ImplementationMarkerIcon(pointingDown: pointingDown, size: size)
        )
    }

    static func appLogo(size: CGFloat = 42) -> LitheLogo {
        LitheLogo(size: size)
    }

    @MainActor
    private static func render(key: String, content: some View) -> NSImage? {
        if let cached = ImageCache.shared.storage[key] { return cached }
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        ImageCache.shared.storage[key] = image
        return image
    }
}

// MARK: - SwiftUI 图标

struct LitheIcon: View {
    let kind: LitheIconKind
    var size: CGFloat = 14

    var body: some View {
        if let image = LitheIcons.ideaImage(for: kind) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            switch LitheIcons.appearance(for: kind) {
            case .letterBadge(let letter, let color):
                LetterBadgeIcon(letter: letter, color: color, size: size)
            case .document(let accent, let mark):
                DocumentIcon(accent: accent, mark: mark, size: size)
            case .folder(let color, let hasBadge):
                FolderIcon(color: color, hasBadge: hasBadge, size: size)
            }
        }
    }
}

/// A small SwiftUI bridge for the imported IntelliJ SVG catalog.
/// `fallbackSystemImage` keeps the UI usable in an unbundled debug preview.
struct LitheIDEAIcon: View {
    let resourcePath: String
    var size: CGFloat = 14
    var fallbackSystemImage: String?

    var body: some View {
        if let image = LitheIcons.ideaImage(resourcePath: resourcePath) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else if let fallbackSystemImage {
            Image(systemName: fallbackSystemImage)
                .font(.system(size: size, weight: .medium))
                .frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

/// Compatibility wrapper for common existing SF Symbol call sites. It uses
/// the official IntelliJ asset when there is a direct match and otherwise
/// preserves the original SF Symbol.
struct LitheSystemIcon: View {
    let systemImage: String
    var size: CGFloat = 14

    var body: some View {
        if let resourcePath = LitheIcons.ideaAssetPath(forSystemImage: systemImage) {
            LitheIDEAIcon(
                resourcePath: resourcePath,
                size: size,
                fallbackSystemImage: systemImage
            )
        } else {
            Image(systemName: systemImage)
        }
    }
}

private struct LetterBadgeIcon: View {
    let letter: String
    let color: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.20))
            Circle()
                .strokeBorder(color.opacity(0.85), lineWidth: max(1, size / 14))
            Text(letter)
                .font(.system(size: size * 0.60, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

private struct DocumentIcon: View {
    let accent: Color
    let mark: LitheIcons.DocumentMark
    let size: CGFloat

    var body: some View {
        ZStack {
            DocumentShape()
                .fill(accent.opacity(0.17))
            DocumentShape()
                .stroke(accent.opacity(0.80), lineWidth: max(1, size / 16))
            markView
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var markView: some View {
        switch mark {
        case .none:
            EmptyView()
        case .letter(let letter):
            Text(letter)
                .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .offset(y: size * 0.11)
        case .lines:
            VStack(spacing: size * 0.11) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(accent.opacity(0.85))
                        .frame(width: size * (index == 2 ? 0.28 : 0.42), height: max(1, size * 0.075))
                }
            }
            .frame(width: size * 0.46, alignment: .leading)
            .offset(y: size * 0.10)
        case .angleBrackets:
            Text("< >")
                .font(.system(size: size * 0.34, weight: .heavy, design: .monospaced))
                .foregroundStyle(accent)
                .offset(y: size * 0.11)
        case .braces:
            Text("{ }")
                .font(.system(size: size * 0.34, weight: .heavy, design: .monospaced))
                .foregroundStyle(accent)
                .offset(y: size * 0.11)
        case .picture:
            PictureMarkShape()
                .fill(accent.opacity(0.90))
                .frame(width: size * 0.50, height: size * 0.34)
                .offset(y: size * 0.13)
        case .cylinder:
            VStack(spacing: size * 0.055) {
                ForEach(0..<3, id: \.self) { _ in
                    Ellipse()
                        .stroke(accent.opacity(0.88), lineWidth: max(1, size * 0.055))
                        .frame(height: size * 0.13)
                }
            }
            .frame(width: size * 0.46)
            .offset(y: size * 0.11)
        }
    }
}

/// 文档轮廓：右上角折角。坐标按 0...1 归一化后乘以 rect，便于任意尺寸复用。
private struct DocumentShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let inset = width * 0.13
        let fold = width * 0.28
        let radius = width * 0.06

        var path = Path()
        path.move(to: CGPoint(x: inset + radius, y: 0))
        path.addLine(to: CGPoint(x: width - inset - fold, y: 0))
        path.addLine(to: CGPoint(x: width - inset, y: fold))
        path.addLine(to: CGPoint(x: width - inset, y: height - radius))
        path.addQuadCurve(
            to: CGPoint(x: width - inset - radius, y: height),
            control: CGPoint(x: width - inset, y: height)
        )
        path.addLine(to: CGPoint(x: inset + radius, y: height))
        path.addQuadCurve(to: CGPoint(x: inset, y: height - radius), control: CGPoint(x: inset, y: height))
        path.addLine(to: CGPoint(x: inset, y: radius))
        path.addQuadCurve(to: CGPoint(x: inset + radius, y: 0), control: CGPoint(x: inset, y: 0))
        path.closeSubpath()
        return path
    }
}

/// 图片标识：一座山 + 一个太阳。
private struct PictureMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.width * 0.36, y: rect.height * 0.32))
        path.addLine(to: CGPoint(x: rect.width * 0.62, y: rect.maxY))
        path.closeSubpath()
        path.addEllipse(in: CGRect(
            x: rect.width * 0.68,
            y: rect.height * 0.08,
            width: rect.width * 0.24,
            height: rect.width * 0.24
        ))
        return path
    }
}

private struct FolderIcon: View {
    let color: Color
    let hasBadge: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
            FolderShape()
                .fill(color.opacity(0.22))
            FolderShape()
                .stroke(color.opacity(0.85), lineWidth: max(1, size / 16))
            if hasBadge {
                Circle()
                    .fill(color)
                    .frame(width: size * 0.26, height: size * 0.26)
                    .offset(x: size * 0.28, y: size * 0.24)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct FolderShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let top = height * 0.18
        let tabWidth = width * 0.42
        let radius = width * 0.07

        var path = Path()
        path.move(to: CGPoint(x: radius, y: height * 0.90))
        path.addLine(to: CGPoint(x: 0 + radius * 0, y: top + radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: top), control: CGPoint(x: 0, y: top))
        path.addLine(to: CGPoint(x: tabWidth * 0.60, y: top))
        path.addLine(to: CGPoint(x: tabWidth * 0.80, y: top - height * 0.10))
        path.addLine(to: CGPoint(x: width - radius, y: top - height * 0.10))
        path.addQuadCurve(
            to: CGPoint(x: width, y: top - height * 0.10 + radius),
            control: CGPoint(x: width, y: top - height * 0.10)
        )
        path.addLine(to: CGPoint(x: width, y: height * 0.90 - radius))
        path.addQuadCurve(to: CGPoint(x: width - radius, y: height * 0.90), control: CGPoint(x: width, y: height * 0.90))
        path.addLine(to: CGPoint(x: radius, y: height * 0.90))
        path.closeSubpath()
        return path
    }
}

// MARK: - gutter 实现标记

struct ImplementationMarkerIcon: View {
    let pointingDown: Bool
    var size: CGFloat = 13

    private var color: Color {
        pointingDown
            ? Color(red: 0.36, green: 0.74, blue: 0.48)
            : Color(red: 0.42, green: 0.66, blue: 0.90)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.18))
            Circle()
                .strokeBorder(color.opacity(0.88), lineWidth: max(1, size / 13))
            ArrowShape(pointingDown: pointingDown)
                .stroke(color, style: StrokeStyle(lineWidth: max(1.2, size / 9), lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.40, height: size * 0.48)
        }
        .frame(width: size, height: size)
    }
}

private struct ArrowShape: Shape {
    let pointingDown: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tipY = pointingDown ? rect.maxY : rect.minY
        let tailY = pointingDown ? rect.minY : rect.maxY
        let headY = pointingDown ? rect.maxY - rect.height * 0.42 : rect.minY + rect.height * 0.42

        path.move(to: CGPoint(x: rect.midX, y: tailY))
        path.addLine(to: CGPoint(x: rect.midX, y: tipY))
        path.move(to: CGPoint(x: rect.minX, y: headY))
        path.addLine(to: CGPoint(x: rect.midX, y: tipY))
        path.addLine(to: CGPoint(x: rect.maxX, y: headY))
        return path
    }
}

// MARK: - 应用 Logo

/// 界面内使用的 Lithe Logo（Welcome 页与顶栏徽章）。
/// 优先复用打包用的 AppIcon.icns，避免界面 Logo 与 Dock 图标不一致。
struct LitheLogo: View {
    var size: CGFloat = 42

    var body: some View {
        Group {
            if let image = originalLogoImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                fallbackLogo
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }

    private var originalLogoImage: NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private var fallbackLogo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.30, green: 0.56, blue: 0.98),
                            Color(red: 0.44, green: 0.32, blue: 0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            LogoGlyphShape()
                .fill(.white)
                .frame(width: size * 0.44, height: size * 0.52)
        }
    }
}

/// Logo 主体：一道向右上倾斜的闪电／L 形折线，呼应 "Lithe"（轻快）。
private struct LogoGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        var path = Path()
        path.move(to: CGPoint(x: width * 0.56, y: 0))
        path.addLine(to: CGPoint(x: width * 0.06, y: height * 0.56))
        path.addLine(to: CGPoint(x: width * 0.44, y: height * 0.56))
        path.addLine(to: CGPoint(x: width * 0.30, y: height))
        path.addLine(to: CGPoint(x: width * 0.94, y: height * 0.40))
        path.addLine(to: CGPoint(x: width * 0.54, y: height * 0.40))
        path.closeSubpath()
        return path
    }
}
