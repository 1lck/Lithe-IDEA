import Foundation

/// Native Services navigation and checkbox selection. Focus and batch selection
/// are independent so browsing another scope never discards checked services.
struct RunBrowserState {
    enum Scope: Hashable {
        case all
        case pinned
        case execution(RunConfigurationExecution)
    }

    enum CheckState {
        case unchecked
        case mixed
        case checked
    }

    struct ApplicationGroup: Identifiable {
        let id: String
        let title: String
        let iconKind: RunConfigurationKind
        let configurations: [RunConfiguration]
    }

    var scope: Scope = .all
    private(set) var checkedIDs: Set<String> = []
    var collapsedGroupIDs: Set<String> = []

    func configurations(
        in scope: Scope,
        from configurations: [RunConfiguration],
        pinnedIDs: Set<String>
    ) -> [RunConfiguration] {
        configurations.filter { configuration in
            guard !configuration.usesCurrentEditorFile else { return false }
            switch scope {
            case .all: return true
            case .pinned: return pinnedIDs.contains(configuration.id)
            case .execution(let execution): return configuration.execution == execution
            }
        }
    }

    func checkState(for configurations: [RunConfiguration]) -> CheckState {
        let ids = Set(configurations.map(\.id))
        let selected = ids.intersection(checkedIDs)
        if selected.isEmpty { return .unchecked }
        return selected == ids ? .checked : .mixed
    }

    mutating func toggle(_ configurations: [RunConfiguration]) {
        let ids = Set(configurations.filter { !$0.usesCurrentEditorFile }.map(\.id))
        if ids.isSubset(of: checkedIDs) {
            checkedIDs.subtract(ids)
        } else {
            checkedIDs.formUnion(ids)
        }
    }

    mutating func restoreSelection(_ ids: [String], configurations: [RunConfiguration]) {
        checkedIDs = Set(ids)
        retainConfigurations(configurations)
    }

    mutating func clearSelection() {
        checkedIDs.removeAll()
    }

    mutating func retainConfigurations(_ configurations: [RunConfiguration]) {
        checkedIDs.formIntersection(configurations.filter { !$0.usesCurrentEditorFile }.map(\.id))
    }

    /// Group by the provider's presentation family; all JVM entry points share
    /// Java while unfamiliar providers keep their own visible group.
    static func groups(for configurations: [RunConfiguration]) -> [ApplicationGroup] {
        let grouped = Dictionary(grouping: configurations.filter { !$0.usesCurrentEditorFile }) {
            $0.kind.capabilities.contains(.javaRuntime) ? "java" : $0.kind.providerID
        }
        return grouped.map { id, configurations in
            let sorted = configurations.sorted {
                let comparison = $0.name.localizedStandardCompare($1.name)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
            let kind = sorted[0].kind
            return ApplicationGroup(
                id: id,
                title: id == "java" ? "Java" : kind.title,
                iconKind: id == "java" ? .javaMain : kind,
                configurations: sorted
            )
        }.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}
