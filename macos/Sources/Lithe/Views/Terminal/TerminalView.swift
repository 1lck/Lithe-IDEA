import SwiftUI
import LitheTerminalModule

struct TerminalView: View {
    @ObservedObject var feature: TerminalFeatureModel
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var terminalHasFocus = false

    var body: some View {
        VStack(spacing: 0) {
            terminalToolbar
            terminalCanvas
        }
        .contentShape(Rectangle())
        .onDrop(
            of: [TerminalTabDragPayload.type],
            delegate: TerminalBarDropDelegate { sessionID in
                guard model.editorTerminalSessions.contains(where: { $0.id == sessionID }) else {
                    return
                }
                model.moveTerminalToTool(sessionID)
            }
        )
        .litheWorkbenchSurface(LitheTheme.editor)
        .onAppear { refreshTerminalFocus() }
        .onChange(of: model.activeToolTerminalSession?.id) { _ in refreshTerminalFocus() }
        .onReceive(NotificationCenter.default.publisher(for: LitheTerminalView.focusDidChange)) { notification in
            guard let view = notification.object as? LitheTerminalView,
                  view === model.activeToolTerminalSession?.nativeView else { return }
            terminalHasFocus = notification.userInfo?["focused"] as? Bool ?? false
        }
    }

    private var terminalToolbar: some View {
        HStack(spacing: 4) {
            Text("Terminal")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(LitheTheme.primaryText)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(model.toolTerminalSessions) { terminalSession in
                        terminalTab(terminalSession)
                    }
                    Button {
                        _ = model.createTerminalSession()
                    } label: {
                        LitheIDEAIcon(resourcePath: "expui/general/add.svg", size: 16,
                                      fallbackSystemImage: "plus", preservesOriginalColors: true)
                    }
                    .litheToolbarIconButton()
                    .help("New terminal session")

                    Menu {
                        Button("New Default Terminal") { _ = model.createTerminalSession() }
                        Divider()
                        ForEach(feature.availableShells, id: \.self) { shell in
                            Button("New \(shellLabel(for: shell))") {
                                _ = model.createTerminalSession(shellPath: shell)
                            }
                        }
                        Divider()
                        Button("Detect Installed Shells") { feature.refreshAvailableShells() }
                    } label: {
                        LitheIDEAIcon(resourcePath: "expui/general/chevronDown.svg", size: 16,
                                      fallbackSystemImage: "chevron.down", preservesOriginalColors: true)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .foregroundStyle(LitheTheme.secondaryText)
                    .help("Detect shells and create a new terminal")
                    .accessibilityLabel("New terminal with shell")
                }
                .padding(.leading, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onDrop(
                of: [TerminalTabDragPayload.type],
                delegate: TerminalBarDropDelegate { sessionID in
                    model.moveTerminalToTool(sessionID)
                }
            )

            Menu {
                if let session = model.activeToolTerminalSession {
                    Button("Interrupt", action: session.interrupt)
                    Button("Restart") {
                        session.restart()
                        session.focus()
                    }
                    .disabled(session.isManagedProcess)
                    Button("Clear", action: session.clear)
                    Divider()
                    Button("Move to Editor") {
                        model.moveTerminalToEditor(session.id)
                    }
                    Button("Close Terminal") {
                        model.requestCloseTerminalSession(session)
                    }
                } else {
                    Button("No Terminal Sessions") {}
                        .disabled(true)
                }
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/moreVertical.svg", size: 16,
                              fallbackSystemImage: "ellipsis", preservesOriginalColors: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .foregroundStyle(LitheTheme.secondaryText)
            .help("Terminal actions")

            Button {
                model.workbenchFeature.setVisibility(.terminal, isVisible: false)
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/hide.svg", size: 16,
                              fallbackSystemImage: "minus", preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .help("Hide Terminal tool window")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 41)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
        .overlay(alignment: .bottom) {
            // IslandsUICustomization gives the tool-window holder 3pt insets.
            Rectangle().fill(headerBorder).frame(height: 1)
                .padding(.horizontal, 3)
        }
    }

    private func terminalTab(_ session: TerminalSession) -> some View {
        let isSelected = model.activeToolTerminalSession?.id == session.id

        return HStack(spacing: 1) {
            HStack(spacing: 6) {
                TerminalToolTabTitle(
                    session: session,
                    fallbackTitle: feature.terminalTitle(for: session)
                )
            }
            .foregroundStyle(isSelected ? LitheTheme.primaryText : LitheTheme.secondaryText)
            .padding(.leading, 12)
            .padding(.trailing, 3)
            .frame(height: 28)
            .contentShape(Rectangle())
            .contentShape(
                .dragPreview,
                RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius)
            )
            .onTapGesture {
                model.selectTerminalSession(session)
                session.focus()
            }
            .onDrag {
                TerminalTabDragPayload.provider(for: session.id)
            } preview: {
                terminalTabDragPreview(session)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(feature.terminalTitle(for: session))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                model.selectTerminalSession(session)
            }

            Button {
                model.requestCloseTerminalSession(session)
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/closeSmall.svg", size: 16,
                              fallbackSystemImage: "xmark", preservesOriginalColors: true)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close \(feature.terminalTitle(for: session))")
        }
        .background(isSelected ? selectedTabBackground : .clear)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? selectedTabBorder : .clear, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .background {
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [TerminalTabDragPayload.type],
                        delegate: TerminalTabDropDelegate(
                            targetSessionID: session.id,
                            targetWidth: geometry.size.width,
                            moveBefore: { sourceID in
                                model.moveTerminalToTool(sourceID, before: session.id)
                            },
                            moveAfter: { sourceID in
                                model.moveTerminalToTool(sourceID, after: session.id)
                            }
                        )
                    )
            }
        }
        .litheContextMenu {
            [
                .action("Move to Editor", systemImage: "rectangle.center.inset.filled", action: {
                    model.moveTerminalToEditor(session.id)
                }),
                .separator,
                .action("Close", systemImage: "xmark", action: {
                    model.requestCloseTerminalSession(session)
                })
            ]
        }
    }

    private var selectedTabBackground: Color {
        guard LitheTheme.activeTheme == .lithe else {
            return terminalHasFocus ? LitheTheme.activeTabBackground : LitheTheme.subtleSelection
        }
        if colorScheme == .dark {
            return terminalHasFocus ? Color(red: 43/255, green: 64/255, blue: 90/255)
                                    : Color(red: 53/255, green: 57/255, blue: 59/255)
        }
        return terminalHasFocus ? Color(red: 227/255, green: 235/255, blue: 254/255)
                                : Color(red: 233/255, green: 234/255, blue: 238/255)
    }

    private var selectedTabBorder: Color {
        guard LitheTheme.activeTheme == .lithe else {
            return terminalHasFocus ? LitheTheme.accent.opacity(0.45) : LitheTheme.divider
        }
        if colorScheme == .dark {
            return terminalHasFocus ? Color(red: 56/255, green: 84/255, blue: 117/255)
                                    : Color(red: 69/255, green: 74/255, blue: 77/255)
        }
        return terminalHasFocus ? Color(red: 167/255, green: 197/255, blue: 255/255)
                                : Color(red: 209/255, green: 211/255, blue: 217/255)
    }

    private var headerBorder: Color {
        guard LitheTheme.activeTheme == .lithe else { return LitheTheme.divider }
        // Islands Dark/Light: ToolWindow.Header.borderColor -> tool-window-border.
        return colorScheme == .dark ? Color(red: 38/255, green: 40/255, blue: 44/255)
                                    : Color(red: 233/255, green: 234/255, blue: 238/255)
    }

    private func refreshTerminalFocus() {
        terminalHasFocus = (model.activeToolTerminalSession?.nativeView as? LitheTerminalView)?.hasFocus == true
    }

    @ViewBuilder
    private var terminalCanvas: some View {
        if let session = model.activeToolTerminalSession {
            TerminalSurfaceView(session: session)
                .id(session.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 34, weight: .ultraLight))
                .foregroundStyle(LitheTheme.tertiaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onDrop(
                    of: [TerminalTabDragPayload.type],
                    delegate: TerminalBarDropDelegate { sessionID in
                        model.moveTerminalToTool(sessionID)
                    }
                )
        }
    }

    private func terminalTabDragPreview(_ session: TerminalSession) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LitheTheme.accent)
            Text(feature.terminalTitle(for: session))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: LitheTheme.Metrics.tabHeight)
        .background(LitheTheme.activeTabBackground)
        .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius))
        .shadow(color: .black.opacity(0.42), radius: 10, y: 6)
    }

    private func shellLabel(for path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return path == "/bin/\(name)" ? name : "\(name) (\(path))"
    }
}

private struct TerminalToolTabTitle: View {
    @ObservedObject var session: TerminalSession
    let fallbackTitle: String

    var body: some View {
        Text(session.isManagedProcess ? fallbackTitle : "Local")
            .font(.system(size: 13, weight: .regular))
            .lineLimit(1)
    }
}

private struct TerminalBarDropDelegate: DropDelegate {
    let receive: @MainActor (UUID) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        !info.itemProviders(for: [TerminalTabDragPayload.type]).isEmpty
    }

    func performDrop(info: DropInfo) -> Bool {
        TerminalTabDragPayload.loadSessionID(
            from: info.itemProviders(for: [TerminalTabDragPayload.type]),
            completion: receive
        )
    }
}

private struct TerminalTabDropDelegate: DropDelegate {
    let targetSessionID: UUID
    let targetWidth: CGFloat
    let moveBefore: @MainActor (UUID) -> Void
    let moveAfter: @MainActor (UUID) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        !info.itemProviders(for: [TerminalTabDragPayload.type]).isEmpty
    }

    func performDrop(info: DropInfo) -> Bool {
        let insertAfter = info.location.x >= targetWidth / 2
        return TerminalTabDragPayload.loadSessionID(
            from: info.itemProviders(for: [TerminalTabDragPayload.type])
        ) { sourceSessionID in
            guard sourceSessionID != targetSessionID else { return }
            if insertAfter {
                moveAfter(sourceSessionID)
            } else {
                moveBefore(sourceSessionID)
            }
        }
    }
}
