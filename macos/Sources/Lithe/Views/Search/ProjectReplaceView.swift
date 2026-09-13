import AppKit
import SwiftUI
import LitheSearchModule

struct ProjectReplaceView: View {
    @ObservedObject var feature: SearchFeatureModel
    @ObservedObject var session: SearchSessionFeatureModel
    let previewReplacement: (String, String, ProjectSearchOptions) async -> Void
    let applyReplacement: (String) async -> Void
    let close: () -> Void
    let openFile: (URL, String) -> Void
    let revealInFinder: (URL) -> Void
    let copyPath: (URL, Bool) -> Void
    @State private var expandedPaths: Set<String> = []
    @State private var query = ""
    @State private var replacement = ""
    @State private var options = ProjectSearchOptions.default
    @State private var isFileMaskEnabled = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case query
        case replacement
        case fileMask
    }

    private var selectedFiles: [ProjectReplacementFile] {
        feature.projectReplacementFiles.filter {
            session.selectedReplacementPaths.contains($0.relativePath)
        }
    }

    private var selectedMatchCount: Int {
        selectedFiles.reduce(0) { $0 + $1.matchCount }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            results
            footer
        }
        .frame(width: 650, height: 614)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(LitheTheme.popupBackground)
                .shadow(color: LitheTheme.popupShadow, radius: 18, y: 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(LitheTheme.panelBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .projectReplaceArrowCursor()
        .onAppear {
            query = session.replacementQuery
            replacement = session.replacementText
            options = session.replacementOptions
            isFileMaskEnabled = !options.fileMask.isEmpty
            focusedField = .query
        }
        .onChange(of: query) { _ in
            clearPreview()
        }
        .onChange(of: replacement) { _ in
            clearPreview()
        }
        .onChange(of: options) { _ in
            clearPreview()
        }
        .onChange(of: isFileMaskEnabled) { _ in
            clearPreview()
        }
        .onExitCommand(perform: close)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Replace in Files")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Spacer()

            Toggle("File mask:", isOn: $isFileMaskEnabled)
                .toggleStyle(ProjectReplaceCheckboxStyle())
                .font(.system(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)

            TextField("*.java", text: $options.fileMask)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .fileMask)
                .projectReplaceTextCursor()
                .padding(.horizontal, 8)
                .projectReplaceInputChrome(isFocused: focusedField == .fileMask, height: 28)
                .frame(width: 96)
                .disabled(!isFileMaskEnabled)
                .opacity(isFileMaskEnabled ? 1 : 0.58)
                .help("Comma-separated glob patterns, e.g. *.java, *.kt")

        }
        .padding(.horizontal, 20)
        .frame(height: 40)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            projectReplaceInput(
                systemImage: "magnifyingglass",
                placeholder: "Find",
                text: $query,
                field: .query
            ) {
                ProjectReplaceOptionButton(title: "Cc", isOn: $options.caseSensitive)
                ProjectReplaceOptionButton(title: "W", isOn: $options.wholeWords)
                ProjectReplaceOptionButton(title: ".*", isOn: $options.regularExpression)
            }

            projectReplaceInput(
                systemImage: "arrow.left.arrow.right",
                placeholder: "Replace",
                text: $replacement,
                field: .replacement
            ) {
                ProjectReplaceOptionButton(
                    title: "Aa",
                    isOn: $options.preserveCase,
                    isEnabled: !options.caseSensitive
                )
            }

            HStack(spacing: 4) {
                Text("In Project")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(LitheTheme.subtleSelection)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text("Project-wide replacement")
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.tertiaryText)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func projectReplaceInput<Accessory: View>(
        systemImage: String,
        placeholder: String,
        text: Binding<String>,
        field: Field,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 16)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focusedField, equals: field)
                .projectReplaceTextCursor()
            HStack(spacing: 3) { accessory() }
        }
        .padding(.horizontal, 8)
        .projectReplaceInputChrome(isFocused: focusedField == field, height: 32)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Preview") {
                Task { await previewReplacement(query, replacement, optionsForPreview) }
            }
            .buttonStyle(ProjectReplaceButtonStyle(isPrimary: true))
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || feature.isLoadingProjectReplacement)

            Button(session.selectedReplacementPaths.count == feature.projectReplacementFiles.count ? "Clear Selection" : "Select All") {
                let allSelected = session.selectedReplacementPaths.count == feature.projectReplacementFiles.count
                session.selectedReplacementPaths = allSelected ? [] : Set(feature.projectReplacementFiles.map(\.relativePath))
            }
            .buttonStyle(ProjectReplaceButtonStyle())
            .disabled(feature.projectReplacementFiles.isEmpty)

            Spacer()

            if feature.isLoadingProjectReplacement {
                ProgressView().controlSize(.small)
            }
            Text("\(selectedFiles.count) files, \(selectedMatchCount) matches")
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
            Button("Replace") {
                Task { await applyReplacement(query) }
            }
            .buttonStyle(ProjectReplaceButtonStyle(isPrimary: true))
            .disabled(selectedFiles.isEmpty || feature.isLoadingProjectReplacement)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)
                .allowsHitTesting(false)
        }
    }

    private var optionsForPreview: ProjectSearchOptions {
        var value = options
        if !isFileMaskEnabled { value.fileMask = "" }
        return value
    }

    @ViewBuilder
    private var results: some View {
        if feature.projectReplacementFiles.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 28, weight: .light))
                Text(query.isEmpty
                    ? "Enter text to preview project changes"
                    : "No replacement matches")
            }
            .font(LitheTheme.uiFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(feature.projectReplacementFiles) { file in
                        fileRow(file)
                        Rectangle().fill(LitheTheme.divider).frame(height: 1)
                    }
                }
            }
            .background(LitheTheme.editor)
        }
    }

    private func fileRow(_ file: ProjectReplacementFile) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedPaths.contains(file.relativePath) },
                set: { expanded in
                    if expanded { expandedPaths.insert(file.relativePath) }
                    else { expandedPaths.remove(file.relativePath) }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(file.matches) { match in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Line \(match.line)  \(match.before)")
                            .foregroundStyle(LitheTheme.secondaryText)
                            .lineLimit(2)
                        Text("        \(match.after)")
                            .foregroundStyle(LitheTheme.primaryText)
                            .lineLimit(2)
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                }
            }
            .padding(.leading, 28)
            .padding(.vertical, 5)
        } label: {
            HStack(spacing: 8) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { session.selectedReplacementPaths.contains(file.relativePath) },
                        set: { selected in
                            if selected { session.selectedReplacementPaths.insert(file.relativePath) }
                            else { session.selectedReplacementPaths.remove(file.relativePath) }
                        }
                    )
                )
                .labelsHidden()
                .lithePointer()
                LitheSystemIcon(systemImage: "doc.text")
                    .foregroundStyle(LitheTheme.secondaryText)
                Text(file.relativePath)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(file.matchCount) matches")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .lithePointer()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .litheContextMenu {
            [
                .action("Open", systemImage: "doc.text", action: {
                    openFile(file.url, file.relativePath)
                }),
                .action("Show in Finder", systemImage: "folder", action: {
                    revealInFinder(file.url)
                }),
                .submenu("Copy Path / Reference", items: [
                    .action("Copy Path", action: {
                        copyPath(file.url, false)
                    }),
                    .action("Copy Relative Path", action: {
                        copyPath(file.url, true)
                    })
                ])
            ]
        }
    }

    private func clearPreview() {
        guard !feature.projectReplacementFiles.isEmpty else { return }
        feature.clearProjectReplacementPreview()
    }
}

private struct ProjectReplaceInputChrome: ViewModifier {
    let isFocused: Bool
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LitheTheme.inputBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isFocused ? LitheTheme.accent : LitheTheme.inputBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

private extension View {
    func projectReplaceInputChrome(isFocused: Bool, height: CGFloat) -> some View {
        modifier(ProjectReplaceInputChrome(isFocused: isFocused, height: height))
    }

    func projectReplaceArrowCursor() -> some View {
        onHover { isInside in
            if isInside {
                NSCursor.arrow.set()
            }
        }
    }

    func projectReplaceTextCursor() -> some View {
        onHover { isInside in
            (isInside ? NSCursor.iBeam : NSCursor.arrow).set()
        }
    }
}

private struct ProjectReplaceOptionButton: View {
    let title: String
    @Binding var isOn: Bool
    var isEnabled = true
    @State private var isHovering = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? LitheTheme.primaryText : LitheTheme.secondaryText)
                .padding(.horizontal, 5)
                .frame(height: 22)
                .background(isOn || isHovering ? LitheTheme.subtleSelection : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovering = $0 }
        .lithePointer()
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
    }

    private var help: String {
        switch title {
        case "Cc": "Match Case"
        case "W": "Whole Words"
        case ".*": "Regular Expression"
        default: "Preserve Case"
        }
    }
}

private struct ProjectReplaceCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(configuration.isOn ? LitheTheme.accent : .clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(configuration.isOn ? LitheTheme.accent : LitheTheme.inputBorder, lineWidth: 1)
                    }
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 14, height: 14)
                configuration.label
            }
        }
        .buttonStyle(.plain)
        .lithePointer()
    }
}

private struct ProjectReplaceButtonStyle: ButtonStyle {
    var isPrimary = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(background(configuration: configuration))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isPrimary && isEnabled ? .clear : LitheTheme.panelBorder, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .lithePointer()
    }

    private var foreground: Color {
        isPrimary && isEnabled ? .white : LitheTheme.secondaryText
    }

    private func background(configuration: Configuration) -> Color {
        guard isEnabled else { return LitheTheme.raised.opacity(0.55) }
        guard isPrimary else { return isHovering ? LitheTheme.raised : LitheTheme.popupBackground }
        return LitheTheme.accent.opacity(configuration.isPressed ? 0.78 : (isHovering ? 1 : 0.9))
    }
}
