import SwiftUI
import LitheModuleAPI
import LitheDatabaseModule
import LitheDebugModule
import LitheExecutionModule
import LitheGitModule
import LitheLanguageIntelligenceModule
import LitheTerminalModule
import LitheAgentConversationModule

@MainActor
enum WorkbenchModuleUIComposition {
    static let builtIn: WorkbenchModuleUIRegistry = {
        do {
            return try WorkbenchModuleUIRegistry(registrations: [
                terminalRegistration,
                agentRegistration,
                gitRegistration,
                languageRegistration,
                executionRegistration,
                databaseRegistration,
                debugRegistration
            ])
        } catch {
            preconditionFailure("Invalid built-in module UI registration: \(error)")
        }
    }()

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
                rightSidebarBehavior: .docked
            )
        ]
    )

    private static let terminalRegistration = WorkbenchModuleUIRegistry.Registration(
        contributions: TerminalModule.moduleContributions,
        actions: [
            .init(id: "terminal.toggle", perform: { $0.toggleTerminal() })
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
            .init(id: "git.log.toggle", perform: { model in
                Task { await model.toggleGitLog() }
            })
        ],
        renderers: [
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
                        )
                    ))
                },
                contentIdentity: { WorkbenchModuleUIRegistry.Renderer.featureIdentity($0.gitFeatureIfActive) }
            )
        ]
    )

    private static let languageRegistration = WorkbenchModuleUIRegistry.Registration(
        contributions: LanguageIntelligenceModule.moduleContributions,
        actions: [
            .init(id: "language.problems.toggle", perform: { $0.toggleProblems() })
        ],
        renderers: [
            .init(
                id: "language.problems",
                ideaAssetPath: "expui/toolwindows/problems@20x20.svg",
                isVisible: { _ in true },
                isSelected: { $0.workbenchFeature.isVisible(.problems) },
                content: { _ in AnyView(ProblemsView()) }
            )
        ]
    )

    private static let executionRegistration = WorkbenchModuleUIRegistry.Registration(
        contributions: ExecutionModule.moduleContributions,
        actions: [
            .init(id: "execution.maven.toggle", perform: { $0.toggleMaven() }),
            .init(id: "execution.maven.output.toggle", perform: { $0.workbenchFeature.toggleVisibility(.mavenOutput) }),
            .init(id: "execution.run.toggle", perform: { $0.toggleRun() }),
            .init(id: "execution.tests.toggle", perform: { $0.toggleTests() })
        ],
        renderers: [
            .init(
                id: "execution.maven",
                ideaAssetPath: "maven/expui/toolwindow/maven@20x20.svg",
                isVisible: { $0.hasMavenProject },
                isSelected: { $0.workbenchFeature.isVisible(.maven) },
                content: { model in
                    guard let feature = model.mavenFeatureIfActive else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView)
                    }
                    return AnyView(MavenView(feature: feature))
                },
                contentIdentity: { WorkbenchModuleUIRegistry.Renderer.featureIdentity($0.mavenFeatureIfActive) },
                rightSidebarBehavior: .docked
            ),
            .init(
                id: "execution.maven.output",
                ideaAssetPath: "expui/toolwindows/run@20x20.svg",
                isVisible: { model in
                    guard let feature = model.mavenFeatureIfActive else { return false }
                    return model.workbenchFeature.isVisible(.mavenOutput)
                        || feature.isRunning || !feature.output.isEmpty || feature.lastExitCode != nil
                        || feature.taskState == .cancelled
                },
                isSelected: { $0.workbenchFeature.isVisible(.mavenOutput) },
                content: { model in
                    guard let feature = model.mavenFeatureIfActive else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView)
                    }
                    return AnyView(MavenBuildOutputView(feature: feature))
                },
                contentIdentity: { WorkbenchModuleUIRegistry.Renderer.featureIdentity($0.mavenFeatureIfActive) }
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
                _ = model.toggleToolWindow(.databaseServices)
            }),
            .init(id: "database.toggle", perform: { model in
                if model.workbenchFeature.isVisible(.database) {
                    model.workbenchFeature.setVisibility(.database, isVisible: false)
                } else {
                    Task { await model.activateDatabaseModule() }
                }
            })
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
            .init(id: "debug.toggle", perform: { $0.toggleDebug() })
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
