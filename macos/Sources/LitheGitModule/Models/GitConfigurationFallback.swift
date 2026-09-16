import Foundation

/// Presentation of defaults with no override for the selected setting.
/// Callers must pass application defaults for reset previews, not resolved
/// repository options; those still contain the override being removed.
package enum GitConfigurationFallback {
    package static func value(for key: String, fetchOptions: GitFetchOptions?, entries: [GitConfigurationEntry]) -> String? {
        switch key {
        case "fetch.prune", "fetch.prunetags", "fetch.recursesubmodules", "pull.rebase", "credential.usehttppath": return "false"
        case "pull.ff": return "true"
        case "push.default": return "simple"
        case "lithe.fetch.prune": return fetchOptions.map { $0.prune ? "true" : "false" }
        case "lithe.fetch.tags": return fetchOptions?.tags.rawValue
        case "lithe.fetch.submodules":
            guard let submodules = fetchOptions?.submodules else { return nil }
            guard submodules == .inherit else { return submodules.rawValue }
            return entries.last(where: { $0.key == "fetch.recursesubmodules" && $0.effective })?.value ?? "false"
        default: return nil
        }
    }
}
