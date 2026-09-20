import Foundation

/// One language-server contribution exposed in the dependency sidebar.
package struct LanguageDependencyDescriptor: Identifiable, Equatable, Sendable {
    package let id: String
    package let displayName: String
    package let providerID: String
    package let systemImage: String

    package init(
        id: String,
        displayName: String,
        providerID: String,
        systemImage: String
    ) {
        self.id = id
        self.displayName = displayName
        self.providerID = providerID
        self.systemImage = systemImage
    }
}

package enum DependencyNodeKind: String, Codable, Equatable, Sendable {
    case group
    case packageNode
    case directory
    case file
    case unavailable
}

package enum DependencySource: Codable, Equatable, Sendable {
    case directory(URL)
    case archive(URL)
    case generated
    case unavailable

    private enum CodingKeys: String, CodingKey {
        case kind
        case url
    }

    private enum Kind: String, Codable {
        case directory
        case archive
        case generated
        case unavailable
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .directory(let url):
            try container.encode(Kind.directory, forKey: .kind)
            try container.encode(url, forKey: .url)
        case .archive(let url):
            try container.encode(Kind.archive, forKey: .kind)
            try container.encode(url, forKey: .url)
        case .generated:
            try container.encode(Kind.generated, forKey: .kind)
        case .unavailable:
            try container.encode(Kind.unavailable, forKey: .kind)
        }
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .directory:
            self = .directory(try container.decode(URL.self, forKey: .url))
        case .archive:
            self = .archive(try container.decode(URL.self, forKey: .url))
        case .generated:
            self = .generated
        case .unavailable:
            self = .unavailable
        }
    }
}

/// A node in the language-neutral dependency browser tree.
package struct DependencyNode: Codable, Identifiable, Equatable, Sendable {
    package let id: String
    package let title: String
    package let subtitle: String?
    package let kind: DependencyNodeKind
    package let source: DependencySource
    package let children: [DependencyNode]

    package init(
        id: String,
        title: String,
        subtitle: String? = nil,
        kind: DependencyNodeKind,
        source: DependencySource,
        children: [DependencyNode] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.source = source
        self.children = children
    }
}

package struct DependencyGraph: Codable, Equatable, Sendable {
    package let providerID: String
    package let roots: [DependencyNode]

    package init(providerID: String, roots: [DependencyNode]) {
        self.providerID = providerID
        self.roots = roots
    }
}
