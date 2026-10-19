import SwiftUI
import LitheModuleAPI
import LitheApplicationKernel
import LitheDatabaseModule
import LitheDebugModule
import LitheExecutionModule
import LitheGitModule
import LitheLanguageIntelligenceModule
import LitheTerminalModule
import LitheWorkspaceModule
import LitheSearchModule
import LitheAgentConversationModule

@MainActor
enum WorkbenchModuleUIComposition {
    static let builtIn: WorkbenchModuleUIRegistry = {
        do {
            return try WorkbenchModuleUIRegistry(registrations: registrations)
        } catch {
            preconditionFailure("Invalid built-in module UI registration: \(error)")
        }
    }()

    /// Application-shell actions outside the module manifests. Startup uses
    /// the same bindings when validating a candidate plugin's UI catalog.
    static var applicationActions: [WorkbenchModuleUIRegistry.Action] {
        [
            .init(id: "workbench.run-start-or-restart", perform: { model in
                if let control = mainToolbarDebugControl(for: model) {
                    model.genericDebugFeatureIfActive?.execute(control == .resume ? .continueExecution : .pause)
                } else if model.activeTestTarget == nil, model.runFeatureIfActive?.isSelectedConfigurationRunning == true { model.restartSelectedRun() }
                else { model.runSelectedConfiguration() }
            }, state: { model in
                let controlsDebug = mainToolbarDebugControl(for: model) != nil
                var state = toolbarState(for: controlsDebug ? .debug : .execution, model: model)
                if controlsDebug { state.isEnabled = state.isEnabled && model.genericDebugFeatureIfActive?.isExecutionRequestPending != true }
                return state
            }),
            .init(id: "workbench.debug-start-or-restart", perform: { $0.startOrRestartDebugging() },
                  state: { toolbarState(for: .debug, model: $0) }),
            .init(id: "workbench.stop-execution", perform: { model in
                if model.genericDebugFeatureIfActive?.isSessionActive == true { model.stopDebugging() }
                else { model.stopSelectedRun() }
            }, state: { model in
                let active = model.genericDebugFeatureIfActive?.isSessionActive == true
                    || model.runFeatureIfActive?.isSelectedConfigurationRunning == true
                return .init(isVisible: active, isEnabled: active)
            })
        ] + LitheCommandCatalog.commands.map { command in
            .init(id: command.id, perform: { model in
                LitheActionRegistry.builtInActions(for: model).first { $0.id == command.id }?.perform()
            }, state: { model in
                .init(isEnabled: model.canPerformShortcutCommand(id: command.id),
                      isChecked: LitheCommandCatalog.toolWindow(for: command.id).map { model.workbenchFeature.isVisible($0) } ?? false)
            })
        }
    }

    private static func toolbarState(for owner: ModuleID, model: AppModel) -> WorkbenchModuleUIRegistry.ActionState {
        .init(isVisible: model.workspaceURL != nil,
              isEnabled: model.workspaceURL != nil && model.services.moduleRuntime.availableContributions()[owner] != nil)
    }

    static func mainToolbarDebugControl(for model: AppModel) -> DebugToolbarActionID? {
        // ponytail: summaries expose launch titles, not configuration IDs; switch to IDs when the debug launch contract carries them.
        DebugToolbarPresentation.mainToolbarControl(state: model.genericDebugFeatureIfActive?.state,
            debugTarget: model.genericDebugFeatureIfActive?.targetTitle,
            selectedTarget: model.activeTestTarget?.name ?? model.runFeatureIfActive?.selectedConfiguration?.name)
    }

    static var registrations: [WorkbenchModuleUIRegistry.Registration] {
        [workspaceRegistration, searchRegistration, terminalRegistration, agentRegistration, gitRegistration, languageRegistration,
         executionRegistration, databaseRegistration, debugRegistration,
         .init(contributions: WorkbenchFeatureModel.shellContributions, actions: applicationActions)]
    }

    static func registry(for catalog: ValidatedPluginCatalog, iconResources: [String: PluginUIIconResources] = [:]) throws -> WorkbenchModuleUIRegistry {
        let plugins = catalog.manifests.filter { $0.entrypoint.kind == .declarative }
        let declarations = plugins.flatMap(\.modules).filter { !$0.contributions.isEmpty }
        // Build-system windows are derived from the declaration, not
        // declared by the plugin, and share one host view.
        let buildSystemModules = Set(plugins.map { ModuleID.buildSystemsExtension($0.id.rawValue) })
        var registry = try WorkbenchModuleUIRegistry(registrations: registrations + declarations.map {
            buildSystemModules.contains($0.manifest.id)
                ? WorkbenchModuleUIRegistry.buildSystemRegistration($0, iconResources: iconResources)
                : WorkbenchModuleUIRegistry.declarativeRegistration($0, iconResources: iconResources)
        })
        registry.registerIcons(declarations.flatMap(\.contributions), resources: iconResources)
        return registry
    }

    private static let workspaceRegistration = WorkbenchModuleUIRegistry.Registration(
        contributions: WorkspaceFoundationModule.moduleContributions,
        actions: [
            .init(id: "workspace.project.show", perform: { $0.workbenchFeature.setVisibility(.project, isVisible: true) }),
            .init(id: "github.pull-requests.show", perform: { model in
                guard LitheFeatureAvailability.githubPullRequests else { return }
                model.workbenchFeature.setVisibility(.pullRequests, isVisible: true)
            })
        ],
        renderers: [
            .init(id: "workspace.project", ideaAssetPath: "expui/toolwindows/project@20x20.svg",
                isVisible: { _ in true }, isSelected: { $0.workbenchFeature.isVisible(.project) },
                content: { AnyView(ProjectSidebarView(rowHeight: $0.settings.projectTreeRowHeight)) },
                contentIdentity: { AnyHashable($0.settings.projectTreeRowHeight) }, rightSidebarBehavior: .docked),
            .init(id: "github.pull-requests", ideaAssetPath: "expui/toolwindows/vcs@20x20.svg",
                isVisible: { _ in true }, isSelected: { $0.workbenchFeature.isVisible(.pullRequests) },
                content: { _ in
                    if LitheFeatureAvailability.githubPullRequests { return AnyView(GitHubPullRequestsSidebarView()) }
                    return AnyView(GitHubFeatureUnavailableView())
                }, rightSidebarBehavior: .docked,
                isEnabled: { _ in LitheFeatureAvailability.githubPullRequests },
                help: LitheFeatureAvailability.githubPullRequests ? nil : "Pull Requests integration is under development")
        ]
    )

    private static let searchRegistration = WorkbenchModuleUIRegistry.Registration(
        contributions: SearchModule.moduleContributions,
        actions: [.init(id: "search.workspace.show", perform: { $0.workbenchFeature.setVisibility(.search, isVisible: true) },
            activateOwner: { await $0.activateSearchModule() != nil })],
        renderers: [
            .init(id: "search.workspace", ideaAssetPath: "expui/toolwindows/find@20x20.svg",
                isVisible: { _ in true }, isSelected: { $0.workbenchFeature.isVisible(.search) },
                content: { model in
                    guard let feature = model.searchFeatureIfActive else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView.task { _ = await model.activateSearchModule() })
                    }
                    return AnyView(SearchSidebarView(
                        feature: feature, session: model.searchSessionFeature,
                        openReplace: { model.openProjectReplace(inheriting: $0) },
                        openResult: { model.openSearchResult($0) },
                        revealInFinder: { model.revealProjectItemInFinder($0) },
                        copyPath: { model.copyProjectItemPath($0, relative: $1) },
                        searchProject: { await model.searchProject(options: $0) }
                    ))
                },
                contentIdentity: { WorkbenchModuleUIRegistry.Renderer.featureIdentity($0.searchFeatureIfActive) },
                rightSidebarBehavior: .docked)
        ]
    )

    private static let agentRegistration = WorkbenchModuleUIRegistry.Registration(
        contributions: AgentConversationModule.moduleContributions,
        actions: [
            .init(id: "agent.conversation.toggle", perform: { $0.toggleAgentConversation() })
        ],
        renderers: [
            .init(
                id: "agent.conversation",
                ideaAssetPath: "toolwindows/toolWindowAgent.svg",
                isVisible: { $0.workspaceURL != nil },
                isSelected: { $0.workbenchFeature.isVisible(.agent) },
                // The panel renders its full layout even before the optional
                // module is active, so the loading placeholder is not used.
                content: { model in AnyView(AgentConversationView(model: model)) },
                contentIdentity: { WorkbenchModuleUIRegistry.Renderer.featureIdentity($0.agentConversationFeatureIfActive) },
                rightSidebarBehavior: .docked,
                openInEditor: { $0.showAgentChatsInEditor() }
            )
        ]
    )

    private static let terminalRegistration = WorkbenchModuleUIRegistry.Registration(
        contributions: TerminalModule.moduleContributions,
        actions: [
            .init(id: "terminal.toggle", perform: { $0.toggleTerminal() }, activateOwner: { await $0.activateTerminalModule() })
        ],
        renderers: [
            .init(
                id: "terminal.sessions",
                ideaAssetPath: "terminal/terminal@20x20.svg",
                isVisible: { _ in true },
                isSelected: { $0.workbenchFeature.isVisible(.terminal) },
                content: { model in
                    guard let feature = model.terminalFeature else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView)
                    }
                    return AnyView(TerminalView(feature: feature))
                },
                contentIdentity: { WorkbenchModuleUIRegistry.Renderer.featureIdentity($0.terminalFeature) }
            )
        ]
    )

    private static let gitRegistration = WorkbenchModuleUIRegistry.Registration(
        contributions: GitModule.moduleContributions,
        actions: [
            .init(id: "git.changes.show", perform: { $0.workbenchFeature.setVisibility(.changes, isVisible: true) },
                activateOwner: { await $0.activateGitModule() != nil }),
            .init(id: "git.log.toggle", perform: { model in
                Task { await model.toggleGitLog() }
            }, activateOwner: { await $0.activateGitModule() != nil })
        ],
        renderers: [
            .init(id: "git.changes", ideaAssetPath: "expui/toolwindows/commit@20x20.svg",
                isVisible: { _ in true }, isSelected: { $0.workbenchFeature.isVisible(.changes) },
                content: { model in
                    guard let feature = model.gitFeatureIfActive else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView.task { _ = await model.activateGitModule() })
                    }
                    return AnyView(ChangesSidebarView(
                        feature: feature, draft: model.commitDraftFeature,
                        commitWorkflow: model.commitWorkflow, workbench: model.workbenchFeature,
                        hasBackgroundImage: model.workbenchBackgroundFeature.hasImage,
                        openSavedDiff: { model.showSavedChangesDiff($0, version: $1, file: $2) },
                        selectChange: { model.selectChange($0) },
                        setStaging: { model.setStaging($0, staged: $1) },
                        openFile: { model.openFile($0, displayPath: $1) },
                        showLocalHistory: { model.showLocalHistory(for: $0) },
                        revealInFinder: { model.revealProjectItemInFinder($0) },
                        copyPath: { model.copyProjectItemPath($0, relative: $1) },
                        showSettings: { model.showSettings(category: $0) }
                    ))
                },
                contentIdentity: { AnyHashable([WorkbenchModuleUIRegistry.Renderer.featureIdentity($0.gitFeatureIfActive),
                    AnyHashable($0.workbenchBackgroundFeature.hasImage)]) },
                rightSidebarBehavior: .docked, help: "Commit"),
            .init(
                id: "git.log",
                ideaAssetPath: "expui/toolwindows/vcs@20x20.svg",
                isVisible: { _ in true },
                isSelected: { $0.workbenchFeature.isVisible(.gitLog) },
                content: { model in
                    guard let feature = model.gitFeatureIfActive else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView)
                    }
                    return AnyView(GitLogView(
                        feature: feature,
                        workbench: model.workbenchFeature,
                        background: model.workbenchBackgroundFeature,
                        projectName: model.projectName,
                        navigation: GitLogNavigation(
                            compareWithWorkingTree: { [weak model] in
                                await model?.showComparisonWithWorkingTree(for: $0)
                            },
                            compareReferences: { [weak model] in
                                await model?.showComparison(from: $0, to: $1)
                            },
                            openCommitDiff: { [weak model] in model?.showGitCommitDiff(for: $0) },
                            openGitSettings: { [weak model] in model?.showSettings(category: .git) },
                            openChanges: { [weak model] in model?.selectedSidebar = .changes }
                        ),
                        worktreeActions: GitWorktreeActions(
                            openProject: { [weak model] in model?.openProject($0) },
                            reveal: { [weak model] in model?.revealProjectItemInFinder($0) },
                            copyPath: { [weak model] in model?.copyProjectItemPath($0, relative: false) },
                            chooseParentDirectory: { [weak model] in
                                model?.platformUI.chooseDirectory(
                                    title: "Choose Worktree Parent", prompt: "Choose"
                                )
                            },
                            openProjectInCurrentWindow: { [weak model] in model?.openProject($0, placement: .thisWindow) },
                            openProjectInNewWindow: { [weak model] in model?.openProject($0, placement: .newWindow) },
                            temporaryDirectory: { [storage = model.services.fileStorage] in storage.temporaryDirectory() }
                        ),
                        presentationCache: model.gitLogPresentationCache
                    ))
                },
                contentIdentity: { WorkbenchModuleUIRegistry.Renderer.featureIdentity($0.gitFeatureIfActive) }
            )
        ]
    )

    private static let languageRegistration = WorkbenchModuleUIRegistry.Registration(
        contributions: LanguageIntelligenceModule.moduleContributions,
        actions: [
            .init(id: "language.problems.toggle", perform: { $0.toggleProblems() }),
            .init(id: "language.references.toggle", perform: { $0.workbenchFeature.toggleVisibility(.references) }),
            .init(id: "language.spring.toggle", perform: { $0.toggleSpringEndpoints() })
        ],
        renderers: [
            .init(
                id: "language.problems",
                ideaAssetPath: "expui/toolwindows/problems@20x20.svg",
                isVisible: { _ in true },
                isSelected: { $0.workbenchFeature.isVisible(.problems) },
                content: { _ in AnyView(ProblemsView()) }
            ),
            .init(id: "language.references", ideaAssetPath: "expui/toolwindows/toolWindowComponents@20x20.svg",
                  isVisible: { $0.workbenchFeature.isVisible(.references) },
                  isSelected: { $0.workbenchFeature.isVisible(.references) },
                  content: { _ in AnyView(LanguageReferencesView()) }),
            .init(id: "language.spring", ideaAssetPath: "expui/toolwindows/toolWindowComponents@20x20.svg",
                  isVisible: { $0.workbenchFeature.isVisible(.spring) },
                  isSelected: { $0.workbenchFeature.isVisible(.spring) },
                  content: { _ in AnyView(SpringEndpointsView()) })
        ]
    )

    private static let executionRegistration = WorkbenchModuleUIRegistry.Registration(
        contributions: ExecutionModule.moduleContributions,
        actions: [
            .init(id: "execution.run.toggle", perform: { $0.toggleRun() }, activateOwner: { await $0.activateExecutionModule() != nil }),
            .init(id: "execution.tests.toggle", perform: { $0.toggleTests() }, activateOwner: { await $0.activateExecutionModule() != nil }),
            .init(id: "execution.build.output.toggle", perform: { $0.workbenchFeature.toggleVisibility(.buildOutput) }, activateOwner: { await $0.activateExecutionModule() != nil })
        ],
        renderers: [
            .init(
                id: "execution.build.output",
                ideaAssetPath: "expui/toolwindows/run@20x20.svg",
                isVisible: { model in
                    guard let feature = model.buildSystemsFeatureIfActive else { return false }
                    return model.workbenchFeature.isVisible(.buildOutput)
                        || feature.runState != .idle || !feature.output.isEmpty
                },
                isSelected: { $0.workbenchFeature.isVisible(.buildOutput) },
                content: { model in
                    guard let feature = model.buildSystemsFeatureIfActive else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView)
                    }
                    return AnyView(BuildOutputView(feature: feature))
                },
                contentIdentity: { WorkbenchModuleUIRegistry.Renderer.featureIdentity($0.buildSystemsFeatureIfActive) }
            ),
            .init(
                id: "execution.run",
                ideaAssetPath: "expui/toolwindows/run@20x20.svg",
                isVisible: { _ in true },
                isSelected: { $0.workbenchFeature.isVisible(.run) },
                content: { model in
                    guard let feature = model.runFeatureIfActive else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView)
                    }
                    return AnyView(RunView(feature: feature))
                },
                contentIdentity: { WorkbenchModuleUIRegistry.Renderer.featureIdentity($0.runFeatureIfActive) }
            ),
            .init(
                id: "execution.tests",
                ideaAssetPath: "expui/toolwindows/coverage@20x20.svg",
                isVisible: { _ in true },
                isSelected: { $0.workbenchFeature.isVisible(.tests) },
                content: { model in
                    guard let service = model.languageTestServiceIfActive else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView)
                    }
                    return AnyView(LanguageTestsView(service: service))
                },
                contentIdentity: { WorkbenchModuleUIRegistry.Renderer.featureIdentity($0.languageTestServiceIfActive) }
            )
        ]
    )

    private static let databaseRegistration = WorkbenchModuleUIRegistry.Registration(
        contributions: DatabaseModule.moduleContributions,
        actions: [
            .init(id: "database.services.toggle", perform: { model in
                if model.workbenchFeature.isVisible(.databaseServices) {
                    model.workbenchFeature.setVisibility(.databaseServices, isVisible: false)
                } else {
                    Task { await model.activateDatabaseModule(toolWindow: .databaseServices) }
                }
            }, activateOwner: { await $0.databaseModuleCoordinator.activate() != nil }),
            .init(id: "database.toggle", perform: { model in
                if model.workbenchFeature.isVisible(.database) {
                    model.workbenchFeature.setVisibility(.database, isVisible: false)
                } else {
                    Task { await model.activateDatabaseModule() }
                }
            }, activateOwner: { await $0.databaseModuleCoordinator.activate() != nil })
        ],
        renderers: [
            .init(id: "database.services", ideaAssetPath: "expui/toolwindows/services@20x20.svg",
                isVisible: { $0.databaseFeatureIfActive != nil },
                isSelected: { $0.workbenchFeature.isVisible(.databaseServices) },
                content: { model in
                    guard let feature = model.databaseFeatureIfActive else { return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView) }
                    return AnyView(DatabaseServicesView().environmentObject(feature))
                },
                contentIdentity: { WorkbenchModuleUIRegistry.Renderer.featureIdentity($0.databaseFeatureIfActive) }),
            .init(
                id: "database.workspace",
                ideaAssetPath: "database/expui/dbms@20x20.svg",
                isVisible: { _ in true },
                isSelected: { $0.workbenchFeature.isVisible(.database) },
                content: { model in
                    guard let feature = model.databaseFeatureIfActive else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView)
                    }
                    return AnyView(DatabaseSidebarView().environmentObject(feature))
                },
                contentIdentity: { WorkbenchModuleUIRegistry.Renderer.featureIdentity($0.databaseFeatureIfActive) },
                rightSidebarBehavior: .docked
            )
        ]
    )

    private static let debugRegistration = WorkbenchModuleUIRegistry.Registration(
        contributions: DebugModule.moduleContributions,
        actions: [
            .init(id: "debug.toggle", perform: { $0.toggleDebug() }, activateOwner: { await $0.activateDebugModule() != nil })
        ],
        renderers: [
            .init(
                id: "debug.session",
                ideaAssetPath: "expui/toolwindows/debug@20x20.svg",
                isVisible: { _ in true },
                isSelected: { $0.workbenchFeature.isVisible(.debug) },
                content: { model in
                    guard let feature = model.genericDebugFeatureIfActive else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView)
                    }
                    return AnyView(GenericDebugView(feature: feature))
                },
                contentIdentity: { WorkbenchModuleUIRegistry.Renderer.featureIdentity($0.genericDebugFeatureIfActive) }
            )
        ]
    )
}
