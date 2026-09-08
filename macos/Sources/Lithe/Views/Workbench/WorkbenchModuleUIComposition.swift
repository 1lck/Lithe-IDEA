import SwiftUI
import LitheModuleAPI
import LitheDebugModule
import LitheExecutionModule
import LitheGitModule
import LitheLanguageIntelligenceModule
import LitheTerminalModule

@MainActor
enum WorkbenchModuleUIComposition {
    static let builtIn: WorkbenchModuleUIRegistry = {
        do {
            return try WorkbenchModuleUIRegistry(registrations: [
                terminalRegistration,
                gitRegistration,
                languageRegistration,
                executionRegistration,
                debugRegistration,
                communityRegistration
            ])
        } catch {
            preconditionFailure("Invalid built-in module UI registration: \(error)")
        }
    }()

    private static let terminalRegistration = WorkbenchModuleUIRegistry.Registration(
        contributions: TerminalModule.moduleContributions,
        actions: [
            .init(id: "terminal.toggle", perform: { $0.toggleTerminal() })
        ],
        renderers: [
            .init(
                id: "terminal.sessions",
                ideaAssetPath: nil,
                isVisible: { _ in true },
                isSelected: { $0.workbenchFeature.isVisible(.terminal) },
                content: { model in
                    guard let feature = model.terminalFeature else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView)
                    }
                    return AnyView(TerminalView(feature: feature))
                }
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
                ideaAssetPath: "toolwindows/toolWindowVcs.svg",
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
                            openCommitDiff: { [weak model] in model?.showGitCommitDiff(for: $0) }
                        ),
                        worktreeActions: GitWorktreeActions(
                            openProject: { [weak model] in model?.openProject($0) },
                            reveal: { [weak model] in model?.revealProjectItemInFinder($0) },
                            copyPath: { [weak model] in model?.copyProjectItemPath($0, relative: false) },
                            chooseParentDirectory: { [weak model] in
                                model?.platformUI.chooseDirectory(
                                    title: "Choose Worktree Parent", prompt: "Choose"
                                )
                            }
                        )
                    ))
                }
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
                ideaAssetPath: "toolwindows/toolWindowProblems.svg",
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
            .init(id: "execution.run.toggle", perform: { $0.toggleRun() }),
            .init(id: "execution.tests.toggle", perform: { $0.toggleTests() })
        ],
        renderers: [
            .init(
                id: "execution.maven",
                ideaAssetPath: "maven/toolWindowMaven.svg",
                isVisible: { $0.hasMavenProject },
                isSelected: { $0.workbenchFeature.isVisible(.maven) },
                content: { model in
                    guard let feature = model.mavenFeatureIfActive else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView)
                    }
                    return AnyView(MavenView(feature: feature))
                }
            ),
            .init(
                id: "execution.run",
                ideaAssetPath: "toolwindows/toolWindowRun.svg",
                isVisible: { _ in true },
                isSelected: { $0.workbenchFeature.isVisible(.run) },
                content: { model in
                    guard let feature = model.runFeatureIfActive else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView)
                    }
                    return AnyView(RunView(feature: feature))
                }
            ),
            .init(
                id: "execution.tests",
                ideaAssetPath: nil,
                isVisible: { _ in true },
                isSelected: { $0.workbenchFeature.isVisible(.tests) },
                content: { model in
                    guard let service = model.languageTestServiceIfActive else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView)
                    }
                    return AnyView(LanguageTestsView(service: service))
                }
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
                ideaAssetPath: "toolwindows/toolWindowDebugger.svg",
                isVisible: { _ in true },
                isSelected: { $0.workbenchFeature.isVisible(.debug) },
                content: { model in
                    guard let feature = model.genericDebugFeatureIfActive else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView)
                    }
                    return AnyView(GenericDebugView(feature: feature))
                }
            )
        ]
    )

    private static let communityRegistration: WorkbenchModuleUIRegistry.Registration = {
        let moduleID = OfficialPluginCatalog.linuxDoSupportModuleID
        let contributions = OfficialPluginCatalog.manifest(forModule: moduleID)?
            .modules.first(where: { $0.manifest.id == moduleID })?
            .contributions ?? []
        return WorkbenchModuleUIRegistry.Registration(
            contributions: contributions,
            actions: [
                .init(id: "community.linux-do.toggle", perform: {
                    $0.isDiscourseCommunityVisible.toggle()
                })
            ],
            renderers: [
                .init(
                    id: "community.linux-do.browser",
                    ideaAssetPath: nil,
                    isVisible: { _ in true },
                    isSelected: { $0.isDiscourseCommunityVisible },
                    content: { _ in
                        AnyView(LinuxDoCommunityView())
                    }
                )
            ]
        )
    }()
}
