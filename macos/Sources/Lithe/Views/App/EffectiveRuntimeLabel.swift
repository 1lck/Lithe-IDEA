import SwiftUI

/// Shows the runtime a launch would use in place of "automatic" or "inherited".
///
/// The value is drawn as a compact card rather than one long monospaced line:
/// the mode and where the runtime came from are badges, the runtime name is the
/// title, and the path stays selectable underneath. Problems use the same card
/// shape with a warning tint so they stand out without turning into plain red
/// paragraphs.
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
        VStack(alignment: .leading, spacing: 6) {
            content(choice())
            ForEach(requirements, id: \.self) { message in
                Label {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.error)
                .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func content(_ choice: RuntimeChoice?) -> some View {
        switch choice {
        case nil:
            detectingCard
        case .found(let url, let source)?:
            runtimeCard(url: url, source: source, mode: modeTitle)
        case .warning(let url, let source, let message)?:
            runtimeCard(url: url, source: source, mode: modeTitle, warning: message)
        case .unavailable(let message)?:
            problemCard(message)
        case .fallback(let invalidPath, let replacement)?:
            VStack(alignment: .leading, spacing: 6) {
                problemCard(String(
                    format: String(localized: "Cannot use %@; using the project JDK instead."),
                    invalidPath
                ))
                fallbackCard(replacement)
            }
        case .invalid(let path)?:
            problemCard(String(format: String(localized: "Cannot be used: %@"), path))
        case .notFound?:
            problemCard(kind == .java
                ? String(localized: "No JDK found. Set JAVA_HOME, install a JDK, or choose a JDK directory.")
                : String(localized: "No Maven found. Add a Maven Wrapper to the project or choose a Maven installation."))
        }
    }

    @ViewBuilder
    private func fallbackCard(_ replacement: RuntimeChoice) -> some View {
        switch replacement {
        case .found(let url, _):
            runtimeCard(url: url, source: .projectJDK, mode: String(localized: "Use Project JDK"))
        case .warning(let url, _, let message):
            runtimeCard(url: url, source: .projectJDK, mode: String(localized: "Use Project JDK"), warning: message)
        case .unavailable(let message):
            problemCard(message)
        case .invalid(let path), .fallback(let path, _):
            problemCard(String(format: String(localized: "Cannot be used: %@"), path))
        case .notFound:
            problemCard(kind == .java
                ? String(localized: "No JDK found. Set JAVA_HOME, install a JDK, or choose a JDK directory.")
                : String(localized: "No Maven found. Add a Maven Wrapper to the project or choose a Maven installation."))
        }
    }

    private var detectingCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Detecting…")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardChrome()
    }

    private func runtimeCard(
        url: URL,
        source: RuntimeChoiceSource,
        mode: String,
        warning: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            iconTile(isWarning: warning != nil)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(mode)
                        .font(LitheTheme.uiFont(size: 10, weight: .semibold))
                        .foregroundStyle(LitheTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(LitheTheme.accent.opacity(0.12))
                        .clipShape(Capsule())
                    if let source = sourceTitle(source) {
                        Text(source)
                            .font(LitheTheme.uiFont(size: 10.5))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                }

                Text(runtimeName(at: url))
                    .font(LitheTheme.uiFont(size: 12.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(LitheTheme.uiFont(size: 9))
                    Text(verbatim: url.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(Text(verbatim: url.path))
                }
                .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)

                if let warning {
                    Label {
                        Text(warning).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.warning)
                    .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardChrome()
    }

    private func problemCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            iconTile(isWarning: true, isError: true)
            Text(message)
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.error.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(LitheTheme.error.opacity(0.28), lineWidth: 1)
        }
    }

    private func iconTile(isWarning: Bool, isError: Bool = false) -> some View {
        let tint = isError ? LitheTheme.error : (isWarning ? LitheTheme.warning : LitheTheme.accent)
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(tint.opacity(0.12))
            .frame(width: 30, height: 30)
            .overlay {
                Image(systemName: isWarning
                    ? "exclamationmark.triangle.fill"
                    : (kind == .java ? "cup.and.saucer.fill" : "shippingbox.fill"))
                    .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
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

    private func runtimeName(at url: URL) -> String {
        switch kind {
        case .java: feature.javaRuntimeName(at: url) ?? "JDK"
        case .maven: feature.mavenRuntimeName(at: url) ?? "Maven"
        }
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

private extension View {
    func cardChrome() -> some View {
        background(LitheTheme.settingsControlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(LitheTheme.settingsControlBorder.opacity(0.8), lineWidth: 1)
            }
    }
}
