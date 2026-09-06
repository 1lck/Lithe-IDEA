import Foundation

/// Builds the application-owned graph before the AppModel shell is created.
///
/// The builder is intentionally limited to object construction. Lifecycle
/// policy and feature behavior remain with the corresponding models.
@MainActor
enum AppCompositionBuilder {
    static func makeModel(
        settings: AppSettings,
        services: AppServices
    ) -> AppModel {
        AppModel(
            settings: settings,
            services: services,
            featureGraph: AppModelFeatureGraph(settings: settings, services: services)
        )
    }
}
