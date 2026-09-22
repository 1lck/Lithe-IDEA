import SwiftUI

/// Shows the runtime a launch would use in place of "automatic" or "inherited",
/// for example `Automatic → Temurin 21.0.4 · /Library/Java/… · from JAVA_HOME`.
struct EffectiveRuntimeLabel: View {
    enum Kind { case java, maven }
    enum Mode { case automatic, inherited, projectJDK, configured }

    @ObservedObject var feature: RuntimeSettingsFeatureModel
    /// Evaluated in `body`, so the label follows discovery and settings changes
    /// even when its parent does not re-render. `nil` while discovery runs.
    let choice: () -> RuntimeChoice?
    let kind: Kind
    let mode: Mode
    /// Core's requirement checks for this toolchain, such as a JDK that is too old.
    var requirements: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            line(choice())
            ForEach(requirements, id: \.self) { message in
                Text(message)
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.error)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func line(_ choice: RuntimeChoice?) -> some View {
        switch choice {
        case nil:
            Text("Detecting…")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
        case .found(let url, let source)?:
            Text(resolvedText(url: url, source: source, mode: modeTitle))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(LitheTheme.primaryText)
                .textSelection(.enabled)
                .lineLimit(3)
        case .fallback(let invalidPath, let replacement)?:
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: String(localized: "Cannot use %@; using the project JDK instead."), invalidPath))
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.error)
                // The project JDK chain yields a JDK, an unusable configured
                // path, or nothing; each must stay visible after the fallback.
                switch replacement {
                case .found(let url, _):
                    Text(resolvedText(url: url, source: .projectJDK, mode: String(localized: "Use Project JDK")))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.primaryText)
                        .textSelection(.enabled)
                case .invalid(let path), .fallback(let path, _):
                    Text(String(format: String(localized: "Cannot be used: %@"), path))
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.error)
                case .notFound:
                    Text("No JDK found. Set JAVA_HOME, install a JDK, or choose a JDK directory.")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.error)
                }
            }
        case .invalid(let path)?:
            Text(String(format: String(localized: "Cannot be used: %@"), path))
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.error)
                .textSelection(.enabled)
        case .notFound?:
            Text(kind == .java
                 ? LocalizedStringKey("No JDK found. Set JAVA_HOME, install a JDK, or choose a JDK directory.")
                 : LocalizedStringKey("No Maven found. Add a Maven Wrapper to the project or choose a Maven installation."))
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.error)
        }
    }

    private var modeTitle: String {
        switch mode {
        case .automatic: String(localized: "Automatic")
        case .inherited: String(localized: "Inherited from project")
        case .projectJDK: String(localized: "Use Project JDK")
        case .configured: String(localized: "Selected runtime")
        }
    }

    private func resolvedText(url: URL, source: RuntimeChoiceSource, mode: String) -> String {
        let name: String
        switch kind {
        case .java: name = feature.javaRuntimeName(at: url) ?? "JDK"
        case .maven: name = feature.mavenRuntimeName(at: url) ?? "Maven"
        }
        var parts = [name, url.path]
        if let source = sourceTitle(source) { parts.append(source) }
        return "\(mode) → " + parts.joined(separator: " · ")
    }

    /// The mode already names configured and inherited values.
    private func sourceTitle(_ source: RuntimeChoiceSource) -> String? {
        switch source {
        case .configured, .projectSetting, .projectJDK: nil
        case .javaHomeEnvironment: String(localized: "from JAVA_HOME")
        case .detected: String(localized: "detected on this Mac")
        case .mavenWrapper: String(localized: "project Maven Wrapper")
        case .systemMaven: String(localized: "system Maven")
        }
    }
}
