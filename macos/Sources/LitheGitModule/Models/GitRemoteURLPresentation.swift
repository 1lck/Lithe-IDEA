import Foundation

/// Safe text and browser targets for the settings UI, never a Git transport URL.
package struct GitRemoteURLPresentation: Sendable {
    package let displayURL: String
    package let browserURL: URL?

    package init?(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }

        var candidate = value
        let isSCP = !value.contains("://")
        if isSCP {
            // Convert Git's user@host:path spelling before parsing; URLComponents
            // then owns escaping and host validation for both output surfaces.
            guard let separator = value.firstIndex(of: ":") else { return nil }
            candidate = "ssh://" + value[..<separator] + "/" + value[value.index(after: separator)...]
        }
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "ssh", "git"].contains(scheme),
              let host = components.host, !host.isEmpty else { return nil }

        components.scheme = scheme
        components.user = nil
        components.password = nil
        // Repository browser links do not need transport queries or fragments.
        // Dropping all of them also covers provider-specific credential names.
        components.query = nil
        components.fragment = nil
        guard let safeURL = components.url else { return nil }
        displayURL = safeURL.absoluteString

        if scheme == "ssh" {
            components.scheme = "https"
            components.port = nil
        }
        browserURL = scheme == "git" ? nil : components.url
    }
}
