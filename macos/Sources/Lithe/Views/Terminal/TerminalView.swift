import AppKit
import SwiftUI
import LitheTerminalModule

struct TerminalView: View {
    @ObservedObject var feature: TerminalFeatureModel
    @EnvironmentObject private var model: AppModel
    @State private var terminalToolActive = false

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
        .background(LitheToolWindowActivityTracker(isActive: $terminalToolActive))
        .onAppear {
            terminalToolActive = (model.activeToolTerminalSession?.nativeView as? LitheTerminalView)?.hasFocus == true
        }
        .onReceive(NotificationCenter.default.publisher(for: LitheTerminalView.focusDidChange)) { notification in
            guard let view = notification.object as? LitheTerminalView,
                  view === model.activeToolTerminalSession?.nativeView else { return }
            guard let focused = notification.userInfo?["focused"] as? Bool else { return }
            terminalToolActive = focused
        }
    }

    private var terminalToolbar: some View {
        HStack(spacing: 0) {
            Text("Terminal")
                .font(LitheTheme.uiFont(size: 13, weight: .bold))
                .foregroundStyle(LitheTheme.primaryText)
                // ToolWindow.headerLabelLeftRightInsets supplies 16pt after the title.
                .padding(.trailing, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.toolTerminalSessions) { terminalSession in
                        terminalTab(terminalSession)
                            // IslandsTabPainter paints 4pt inside each tab's layout bounds.
                            .padding(.horizontal, 4)
                    }
                    Button {
                        _ = model.createTerminalSession()
                    } label: {
                        LitheIDEAIcon(resourcePath: "expui/general/add.svg", size: 16,
                                      fallbackSystemImage: "plus", preservesOriginalColors: true)
                    }
                    .litheToolbarIconButton()
                    .padding(.horizontal, 2)
                    .help("New terminal session")

                    LitheMenu {
                        shellMenuItems
                    } label: {
                        LitheIDEAIcon(resourcePath: "expui/general/chevronDownLarge.svg", size: 16,
                                      fallbackSystemImage: "chevron.down", preservesOriginalColors: true)
                    }
                    .litheToolbarIconButton()
                    .padding(.horizontal, 2)
                    .help("Detect shells and create a new terminal")
                    .accessibilityLabel("New terminal with shell")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onDrop(
                of: [TerminalTabDragPayload.type],
                delegate: TerminalBarDropDelegate { sessionID in
                    model.moveTerminalToTool(sessionID)
                }
            )

            LitheMenu {
                terminalActionsMenuItems
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/moreVertical.svg", size: 16,
                              fallbackSystemImage: "ellipsis", preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .padding(.horizontal, 2)
            .help("Terminal actions")

            Button {
                model.workbenchFeature.setVisibility(.terminal, isVisible: false)
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/hide.svg", size: 16,
                              fallbackSystemImage: "minus", preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .padding(.horizontal, 2)
            .help("Hide Terminal tool window")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 41)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
        .overlay(alignment: .bottom) {
            LitheToolWindowHeaderDivider()
        }
    }

    private func terminalTab(_ session: TerminalSession) -> some View {
        let isSelected = model.activeToolTerminalSession?.id == session.id
        let title = terminalTabTitle(for: session)

        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                TerminalToolTabTitle(
                    session: session,
                    fallbackTitle: title
                )
            }
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.leading, 8)
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
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .help(title)
            .accessibilityAction {
                model.selectTerminalSession(session)
            }

            LitheToolWindowTabCloseButton {
                model.requestCloseTerminalSession(session)
            }
            .help("Close \(title)")
        }
        .modifier(LitheToolWindowTabStyle(isSelected: isSelected, isActive: terminalToolActive))
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

    private func terminalTabTitle(for session: TerminalSession) -> String {
        feature.toolTabTitle(for: session, orderedSessions: model.toolTerminalSessions)
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
                .font(LitheTheme.uiFont(size: 34, weight: .ultraLight))
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
                .font(LitheTheme.uiFont(size: 11, weight: .medium))
                .foregroundStyle(LitheTheme.accent)
            Text(terminalTabTitle(for: session))
                .font(LitheTheme.uiFont(size: 12, weight: .medium))
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

    private var shellMenuItems: [LitheContextMenuItem] {
        var items: [LitheContextMenuItem] = [
            .action("New Default Terminal") { _ = model.createTerminalSession() }
        ]
        if !feature.availableShells.isEmpty {
            items.append(.separator)
            items += feature.availableShells.map { shell in
                .action("New \(shellLabel(for: shell))") { _ = model.createTerminalSession(shellPath: shell) }
            }
        }
        items += [
            .separator,
            .action("Detect Installed Shells") { feature.refreshAvailableShells() }
        ]
        return items
    }

    private var terminalActionsMenuItems: [LitheContextMenuItem] {
        guard let session = model.activeToolTerminalSession else {
            return [.action("No Terminal Sessions", isEnabled: false, action: {})]
        }
        return [
            .action("Interrupt", action: session.interrupt),
            .action("Restart", isEnabled: !session.isManagedProcess) {
                session.restart()
                session.focus()
            },
            .action("Clear", action: session.clear),
            .separator,
            .action("Move to Editor") { model.moveTerminalToEditor(session.id) },
            .action("Close Terminal") { model.requestCloseTerminalSession(session) }
        ]
    }
}

private struct TerminalToolTabTitle: View {
    @ObservedObject var session: TerminalSession
    let fallbackTitle: String

    var body: some View {
        Text(session.isManagedProcess ? session.processTitle ?? fallbackTitle : fallbackTitle)
            .font(LitheTheme.uiFont(size: 13, weight: .regular))
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
