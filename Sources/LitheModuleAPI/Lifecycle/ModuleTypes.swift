import Foundation

public struct ModuleID: RawRepresentable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "A module ID must not be empty.")
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ModuleCapabilityID: RawRepresentable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "A capability ID must not be empty.")
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ModuleScope: String, Codable, Sendable {
    case application
    case workspace
}

public enum ModuleDefaultState: String, Codable, Sendable {
    case enabled
    case disabled
}

public enum ModuleActivationPolicy: String, Codable, Sendable {
    case eager
    case onDemand
    case manual
}

public enum ModuleLaunchMode: Sendable {
    case normal
    case safeMode
}

public enum ModuleSleepPolicy: Equatable, Codable, Sendable {
    case never
    case whenIdle(afterSeconds: TimeInterval)

    public var idleInterval: TimeInterval? {
        switch self {
        case .never: nil
        case .whenIdle(let interval): interval
        }
    }
}

public enum ModuleDependency: Hashable, Codable, Sendable {
    case module(ModuleID)
    case capability(ModuleCapabilityID)
}

public struct ModuleManifest: Equatable, Codable, Sendable {
    public let id: ModuleID
    public let displayName: String
    public let scope: ModuleScope
    public let defaultState: ModuleDefaultState
    public let activationPolicy: ModuleActivationPolicy
    public let sleepPolicy: ModuleSleepPolicy
    public let dependencies: Set<ModuleDependency>
    public let providedCapabilities: Set<ModuleCapabilityID>
    public let isRequired: Bool

    public init(
        id: ModuleID,
        displayName: String,
        scope: ModuleScope,
        defaultState: ModuleDefaultState = .enabled,
        activationPolicy: ModuleActivationPolicy = .onDemand,
        sleepPolicy: ModuleSleepPolicy = .never,
        dependencies: Set<ModuleDependency> = [],
        providedCapabilities: Set<ModuleCapabilityID> = [],
        isRequired: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.scope = scope
        self.defaultState = defaultState
        self.activationPolicy = activationPolicy
        self.sleepPolicy = sleepPolicy
        self.dependencies = dependencies
        self.providedCapabilities = providedCapabilities
        self.isRequired = isRequired
    }
}

public enum ModuleState: Equatable, Sendable {
    case disabled
    case inactive
    case activating
    case active
    case idle
    case preparingToSleep
    case sleeping
    case sleepBlocked(reason: String)
    case failed(message: String)
}

public struct ModuleActivity: Equatable, Sendable {
    public let activeLeaseCount: Int
    public let activeResourceCount: Int
    public let lastActivityAt: Date?

    public init(
        activeLeaseCount: Int,
        activeResourceCount: Int,
        lastActivityAt: Date?
    ) {
        self.activeLeaseCount = activeLeaseCount
        self.activeResourceCount = activeResourceCount
        self.lastActivityAt = lastActivityAt
    }

    public var isIdle: Bool {
        activeLeaseCount == 0
    }
}

public struct ModuleSnapshot: Equatable, Sendable {
    public let manifest: ModuleManifest
    public let state: ModuleState
    public let activity: ModuleActivity
    public let isInstantiated: Bool
    public let resources: [ModuleResourceSnapshot]
    public let activeLeaseReasons: [String]
    public let isQuarantined: Bool
    public let isSuppressedBySafeMode: Bool

    public init(
        manifest: ModuleManifest,
        state: ModuleState,
        activity: ModuleActivity,
        isInstantiated: Bool,
        resources: [ModuleResourceSnapshot] = [],
        activeLeaseReasons: [String] = [],
        isQuarantined: Bool = false,
        isSuppressedBySafeMode: Bool = false
    ) {
        self.manifest = manifest
        self.state = state
        self.activity = activity
        self.isInstantiated = isInstantiated
        self.resources = resources
        self.activeLeaseReasons = activeLeaseReasons
        self.isQuarantined = isQuarantined
        self.isSuppressedBySafeMode = isSuppressedBySafeMode
    }
}

public enum ModuleContributionKind: String, Codable, Sendable {
    case command
    case toolWindow
    case settings
    case status
}

public enum ModuleContributionPlacement: String, Codable, Sendable {
    case activityBar
    case rightSidebar
    case toolWindow
    case commandPalette
    case settings
    case statusBar
}

public struct ModuleContribution: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let kind: ModuleContributionKind
    public let title: String
    public let icon: String?
    public let placement: ModuleContributionPlacement
    public let order: Int
    public let actionID: String?
    public let rendererID: String?
    public let visibility: [String: String]

    public init(
        id: String,
        kind: ModuleContributionKind,
        title: String,
        icon: String? = nil,
        placement: ModuleContributionPlacement? = nil,
        order: Int = 0,
        actionID: String? = nil,
        rendererID: String? = nil,
        visibility: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.icon = icon
        self.placement = placement ?? Self.defaultPlacement(for: kind)
        self.order = order
        self.actionID = actionID
        self.rendererID = rendererID
        self.visibility = visibility
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, icon, placement, order, actionID, rendererID, visibility
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(ModuleContributionKind.self, forKey: .kind)
        self.id = try container.decode(String.self, forKey: .id)
        self.kind = kind
        title = try container.decode(String.self, forKey: .title)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        placement = try container.decodeIfPresent(
            ModuleContributionPlacement.self,
            forKey: .placement
        ) ?? Self.defaultPlacement(for: kind)
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        actionID = try container.decodeIfPresent(String.self, forKey: .actionID)
        rendererID = try container.decodeIfPresent(String.self, forKey: .rendererID)
        visibility = try container.decodeIfPresent(
            [String: String].self,
            forKey: .visibility
        ) ?? [:]
    }

    private static func defaultPlacement(
        for kind: ModuleContributionKind
    ) -> ModuleContributionPlacement {
        switch kind {
        case .command: .commandPalette
        case .toolWindow: .activityBar
        case .settings: .settings
        case .status: .statusBar
        }
    }
}

public extension ModuleID {
    static let workspace = ModuleID("dev.lithe.workspace")
    static let git = ModuleID("dev.lithe.git")
    static let search = ModuleID("dev.lithe.search")
    static let localHistory = ModuleID("dev.lithe.local-history")
    static let languageIntelligence = ModuleID("dev.lithe.language-intelligence")
    static let execution = ModuleID("dev.lithe.execution")
    static let debug = ModuleID("dev.lithe.debug")
    static let terminal = ModuleID("dev.lithe.terminal")
    static let database = ModuleID("dev.lithe.database")
    static let aiAssistance = ModuleID("dev.lithe.ai-assistance")

    static func languageServerExtension(_ languageID: String) -> ModuleID {
        ModuleID("dev.lithe.language.\(languageID).language-server")
    }

    static func languageExecutionExtension(_ languageID: String) -> ModuleID {
        ModuleID("dev.lithe.language.\(languageID).execution")
    }
}

public extension ModuleCapabilityID {
    static let workspaceFoundation = ModuleCapabilityID("dev.lithe.capability.workspace-foundation")
    static let gitWorkspace = ModuleCapabilityID("dev.lithe.capability.git-workspace")
    static let searchWorkspace = ModuleCapabilityID("dev.lithe.capability.search-workspace")
    static let historyWorkspace = ModuleCapabilityID("dev.lithe.capability.history-workspace")
    static let languageIntelligence = ModuleCapabilityID("dev.lithe.capability.language-intelligence")
    static let executionWorkspace = ModuleCapabilityID("dev.lithe.capability.execution-workspace")
    static let debugWorkspace = ModuleCapabilityID("dev.lithe.capability.debug-workspace")
    static let terminalWorkspace = ModuleCapabilityID("dev.lithe.capability.terminal-workspace")
    static let databaseWorkspace = ModuleCapabilityID("dev.lithe.capability.database-workspace")
    static let aiCommitMessage = ModuleCapabilityID("dev.lithe.capability.ai-commit-message")
    static let aiPullRequestDescription = ModuleCapabilityID("dev.lithe.capability.ai-pull-request-description")

    static func languageServerExtension(_ languageID: String) -> ModuleCapabilityID {
        ModuleCapabilityID("dev.lithe.capability.language.\(languageID).language-server")
    }

    static func languageExecutionExtension(_ languageID: String) -> ModuleCapabilityID {
        ModuleCapabilityID("dev.lithe.capability.language.\(languageID).execution")
    }

    static func languageTestingExtension(_ languageID: String) -> ModuleCapabilityID {
        ModuleCapabilityID("dev.lithe.capability.language.\(languageID).testing")
    }
}
