import AppKit
import Foundation
import ImageIO
import LitheCoreContracts
import LitheModuleAPI

/// Icons are read only from the verified package, never from a network URL or
/// writable bundle cache. Ownership ends with this process's accepted catalog.
enum MacPluginUIIconLoader {
    static func load(_ descriptor: DeclarativePluginDescriptor, at packageURL: URL) throws -> [String: PluginUIIconResources] {
        let root = packageURL.standardizedFileURL.resolvingSymlinksInPath()
        var assets: [String: Data] = [:]
        var totalBytes = 0
        var totalPixels = 0
        func readChecked(_ path: String) throws -> Data {
            if let data = assets[path] { return data }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !path.contains(":"), !path.contains("\\"), !path.contains("\0"),
                  ["svg", "png"].contains((path as NSString).pathExtension) else { throw InvalidIcon(path: path) }
            var url = root
            for component in components {
                url.appendPathComponent(String(component))
                guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw InvalidIcon(path: path)
                }
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 262_144,
                  url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw InvalidIcon(path: path) }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 262_145) ?? Data()
            guard data.count <= 262_144, totalBytes + data.count <= 8_388_608 else { throw InvalidIcon(path: path) }
            var pixels = 0
            if path.hasSuffix(".svg") {
                guard SVGIconValidator.accepts(data) else { throw InvalidIcon(path: path) }
            } else {
                guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
                      let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      (1...1024).contains(width), (1...1024).contains(height) else { throw InvalidIcon(path: path) }
                pixels = width * height
                guard totalPixels + pixels <= 4_194_304,
                      CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw InvalidIcon(path: path) }
            }
            guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
                  image.size.width <= 1024, image.size.height <= 1024 else { throw InvalidIcon(path: path) }
            totalPixels += pixels == 0 ? Int(image.size.width * image.size.height) : pixels
            guard totalPixels <= 4_194_304 else { throw InvalidIcon(path: path) }
            assets[path] = data
            totalBytes += data.count
            return data
        }
        func read(_ path: String) throws -> Data {
            do { return try readChecked(path) } catch { throw InvalidIcon(path: path) }
        }
        var result: [String: PluginUIIconResources] = [:]
        for contribution in descriptor.pluginManifest.modules.flatMap(\.contributions) {
            guard let icon = contribution.uiIcon, let path = icon.path else { continue }
            result[contribution.id] = try PluginUIIconResources(light: read(path), dark: icon.darkPath.map(read))
        }
        // Toolbar options of a build-system window.
        for buildSystem in descriptor.buildSystems {
            let window = DeclarativeBuildSystem.toolWindowID(
                pluginID: descriptor.id.rawValue, buildSystemID: buildSystem.id
            )
            for option in buildSystem.options {
                guard let icon = option.icon, let path = icon.path else { continue }
                result[DeclarativeBuildSystem.optionIconID(toolWindowID: window, optionID: option.id)] =
                    try PluginUIIconResources(light: read(path), dark: icon.darkPath.map(read))
            }
        }
        return result
    }

    struct InvalidIcon: LocalizedError {
        let path: String
        var errorDescription: String? { "Invalid plugin icon resource: \(path)" }
    }
}

/// A bounded static SVG subset. XMLParser is the system parser; executable,
/// external-reference and document-type constructs never reach the decoder.
private final class SVGIconValidator: NSObject, XMLParserDelegate {
    private var valid = true
    private var count = 0
    private let elements: Set<String> = ["svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "defs", "linearGradient", "radialGradient", "stop", "clipPath", "title", "desc"]
    private let attributes: Set<String> = ["xmlns", "version", "id", "viewBox", "width", "height", "x", "y", "x1", "x2", "y1", "y2", "cx", "cy", "fx", "fy", "r", "rx", "ry", "d", "points", "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "fill-rule", "clip-rule", "clip-path", "opacity", "fill-opacity", "stroke-opacity", "transform", "gradientTransform", "gradientUnits", "offset", "stop-color", "stop-opacity", "preserveAspectRatio"]

    static func accepts(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8),
              !text.lowercased().contains("<!doctype"), !text.lowercased().contains("<!entity") else { return false }
        let validator = SVGIconValidator()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = validator
        return parser.parse() && validator.valid && validator.count > 0
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes values: [String: String]) {
        count += 1
        valid = valid && count <= 4096 && elements.contains(elementName)
        if count == 1 {
            let box = values["viewBox"]?.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { Double($0) }
            let width = values["width"].flatMap(Double.init) ?? (box?.count == 4 ? box?[2] : nil)
            let height = values["height"].flatMap(Double.init) ?? (box?.count == 4 ? box?[3] : nil)
            valid = valid && elementName == "svg" && width.map { $0 > 0 && $0 <= 1024 } == true
                && height.map { $0 > 0 && $0 <= 1024 } == true
        }
        for (key, value) in values {
            // Local paint-server/clip references are the only URLs allowed.
            let stripped = value.replacingOccurrences(of: "url\\(#[A-Za-z0-9_-]+\\)", with: "", options: .regularExpression)
            valid = valid && attributes.contains(key) && (key == "xmlns" ? value == "http://www.w3.org/2000/svg"
                : !stripped.contains(":") && !stripped.lowercased().contains("url("))
        }
        if !valid { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        valid = false
        parser.abortParsing()
    }
}
