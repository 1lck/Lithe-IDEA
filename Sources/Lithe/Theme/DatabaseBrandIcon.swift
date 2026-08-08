import AppKit
import SwiftUI

extension DatabaseKind {
    var brandIconFilename: String {
        switch self {
        case .mysql: "mysql.svg"
        case .mariadb: "mariadb.svg"
        case .postgresql: "postgres.svg"
        case .sqlite: "sqlite.svg"
        case .sqlserver: "sqlserver.svg"
        case .mongodb: "mongodb.svg"
        case .redis: "redis.svg"
        case .nacos: "nacos.png"
        }
    }

    var brandIconFallbackSymbol: String {
        switch self {
        case .mysql: "cylinder.fill"
        case .mariadb: "cylinder.fill"
        case .postgresql: "cylinder.split.1x2.fill"
        case .sqlite: "externaldrive.fill"
        case .sqlserver: "server.rack"
        case .mongodb: "leaf.fill"
        case .redis: "square.stack.3d.up.fill"
        case .nacos: "slider.horizontal.3"
        }
    }
}

@MainActor
private enum DatabaseBrandIconLoader {
    private struct CacheKey: Hashable {
        let kind: DatabaseKind
        let size: Int
    }

    private static var cache: [CacheKey: NSImage] = [:]

    static func image(for kind: DatabaseKind, size: CGFloat) -> NSImage? {
        let key = CacheKey(kind: kind, size: max(1, Int(size.rounded())))
        if let cached = cache[key] { return cached }
        let filename = kind.brandIconFilename as NSString
        guard let url = Bundle.main.url(
            forResource: filename.deletingPathExtension,
            withExtension: filename.pathExtension,
            subdirectory: "DatabaseIcons"
        ), let image = NSImage(contentsOf: url) else {
            return nil
        }
        // SwiftUI respects the view frame, but AppKit menu bridging reads the
        // NSImage's intrinsic size. Normalize both so vector assets cannot
        // expand a system menu to their original SVG canvas dimensions.
        image.size = NSSize(width: CGFloat(key.size), height: CGFloat(key.size))
        image.isTemplate = false
        cache[key] = image
        return image
    }
}

/// Database vendor mark used only for type recognition. The system-image
/// fallback keeps unbundled development builds and future platforms usable.
struct DatabaseBrandIcon: View {
    let kind: DatabaseKind
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let image = DatabaseBrandIconLoader.image(for: kind, size: size) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: kind.brandIconFallbackSymbol)
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(LitheTheme.accent)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
