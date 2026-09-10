import LitheDebugModule
import LitheExecutionModule

/// The debug feature exposed to application workflows after activation.
@MainActor
struct DebugFeatureAccess {
    let genericFeature: GenericDebugFeatureModel
}

/// The execution features exposed to application workflows after activation.
@MainActor
struct ExecutionFeatureAccess {
    let mavenFeature: MavenFeatureModel
    let runFeature: RunFeatureModel
    let tests: LanguageTestService
    let projectDevelopment: ProjectDevelopmentFeatureModel
}
