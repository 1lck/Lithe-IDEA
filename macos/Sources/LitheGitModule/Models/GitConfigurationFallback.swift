import Foundation

/// Presentation of defaults with no override for the selected setting.
/// Callers must pass application defaults for reset previews, not resolved
/// repository options; those still contain the override being removed.
package enum GitConfigurationFallback {
    /// Concrete tag transfer inherited by `lithe.fetch.tags = inherit`, plus the
    /// entry that decided it. `value` is a display token, not a choice value.
    package struct InheritedTagBehavior {
        package let value: String
        package let source: GitConfigurationEntry?
        package init(value: String, source: GitConfigurationEntry?) {
            self.value = value
            self.source = source
        }
    }

    package static func value(for key: String, fetchOptions: GitFetchOptions?, entries: [GitConfigurationEntry]) -> String? {
        switch key {
        case "fetch.prune", "fetch.prunetags", "fetch.recursesubmodules", "pull.rebase", "credential.usehttppath": return "false"
        case "pull.ff": return "true"
        case "push.default": return "simple"
        case "lithe.fetch.prune": return fetchOptions.map { $0.prune ? "true" : "false" }
        case "lithe.fetch.tags":
            guard let tags = fetchOptions?.tags else { return nil }
            guard tags == .inherit else { return tags.rawValue }
            return inheritedTagBehavior(
                remote: fetchOptions?.remote,
                prune: fetchOptions?.prune ?? false,
                entries: entries
            ).value
        case "lithe.fetch.submodules":
            guard let submodules = fetchOptions?.submodules else { return nil }
            guard submodules == .inherit else { return submodules.rawValue }
            return entries.last(where: { $0.key == "fetch.recursesubmodules" && $0.effective })?.value ?? "false"
        default: return nil
        }
    }

    /// Resolves `lithe.fetch.tags = inherit` to the behavior Fetch will apply.
    ///
    /// Git leaves tag transfer to each remote: `remote.<name>.tagOpt` selects all
    /// or no tags, and `fetch.pruneTags` (per remote or global) switches to the
    /// all-tags refspec, which Lithe prunes when its Fetch prunes. Remotes that
    /// disagree have no single honest value, so the token says so instead of
    /// guessing one of them.
    package static func inheritedTagBehavior(
        remote: String?,
        prune: Bool,
        entries: [GitConfigurationEntry]
    ) -> InheritedTagBehavior {
        let remotes = targetedRemotes(remote: remote, entries: entries)
        guard !remotes.isEmpty else {
            return InheritedTagBehavior(value: "reachable", source: nil)
        }
        let resolved = remotes.map { name -> InheritedTagBehavior in
            let remotePruneTags = entries.last { $0.key == "remote.\(name).prunetags" && $0.effective }
            let pruneTags = remotePruneTags
                ?? entries.last { $0.key == "fetch.prunetags" && $0.effective }
            // Core inspection uses Git's boolean parser to canonicalize these
            // effective entries; raw invalid values keep the tagOpt fallback.
            if pruneTags?.value == "true" {
                // The all-tags refspec fetches every tag; only a pruning Fetch
                // additionally removes the ones the remote no longer has.
                return InheritedTagBehavior(value: prune ? "prune" : "all", source: pruneTags)
            }
            let tagOpt = entries.last { $0.key == "remote.\(name).tagopt" && $0.effective }
            switch tagOpt?.value {
            case "--no-tags": return InheritedTagBehavior(value: "none", source: tagOpt)
            case "--tags": return InheritedTagBehavior(value: "all", source: tagOpt)
            default: return InheritedTagBehavior(value: "reachable", source: nil)
            }
        }
        guard let first = resolved.first else {
            return InheritedTagBehavior(value: "reachable", source: nil)
        }
        guard resolved.allSatisfy({ $0.value == first.value }) else {
            return InheritedTagBehavior(value: "remoteDependent", source: nil)
        }
        return InheritedTagBehavior(value: first.value, source: resolved.compactMap(\.source).first)
    }

    private static func targetedRemotes(remote: String?, entries: [GitConfigurationEntry]) -> [String] {
        if let remote { return [remote] }
        var names: [String] = []
        for entry in entries where entry.effective && entry.key.hasPrefix("remote.") && entry.key.hasSuffix(".url") {
            let name = String(entry.key.dropFirst("remote.".count).dropLast(".url".count))
            // Fetch ignores `remote.<name>.skipFetchAll` remotes when it fetches
            // every remote; their tagOpt must not make the inherited value look
            // remote-dependent. An explicitly selected remote is still used.
            let skipped = entries.last {
                $0.key == "remote.\(name).skipfetchall" && $0.effective
            }?.value == "true"
            if !skipped && !names.contains(name) { names.append(name) }
        }
        return names
    }
}
