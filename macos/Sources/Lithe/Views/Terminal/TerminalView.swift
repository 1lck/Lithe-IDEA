import SwiftUI
import LitheTerminalModule

struct TerminalView: View {
    @ObservedObject var feature: TerminalFeatureModel
    @EnvironmentObject private var model: AppModel

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
    }

    private var terminalToolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
            Text("Terminal")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(model.toolTerminalSessions) { terminalSession in
                        terminalTab(terminalSession)
                    }
                }
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onDrop(
                of: [TerminalTabDragPayload.type],
                delegate: TerminalBarDropDelegate { sessionID in
                    model.moveTerminalToTool(sessionID)
                }
            )

            if let session = model.activeToolTerminalSession {
                TerminalStatusView(session: session)
            }

            Button {
                _ = model.createTerminalSession()
            } label: {
                Image(systemName: "plus")
            }
            .litheIconButton()
            .help("New terminal session")

            Menu {
                ForEach(feature.availableShells, id: \.self) { shell in
                    Button("New \(shellLabel(for: shell))") {
                        _ = model.createTerminalSession(shellPath: shell)
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .lithePointer()
            .menuIndicator(.hidden)
            .frame(width: 26, height: 28)
            .contentShape(Rectangle())
            .foregroundStyle(LitheTheme.secondaryText)
            .help("New terminal with shell")

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
                LitheSystemIcon(systemImage: "ellipsis.vertical")
            }
            .menuStyle(.borderlessButton)
            .lithePointer()
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .foregroundStyle(LitheTheme.secondaryText)
            .help("Terminal actions")

            Button {
                model.workbenchFeature.setVisibility(.terminal, isVisible: false)
            } label: {
                Image(systemName: "minus")
            }
            .litheIconButton()
            .help("Hide Terminal tool window")
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: LitheTheme.Metrics.toolWindowHeaderHeight)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
        }
    }

    private func terminalTab(_ session: TerminalSession) -> some View {
        let isActive = model.activeToolTerminalSession?.id == session.id

        return HStack(spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .medium))
                TerminalToolTabTitle(
                    session: session,
                    fallbackTitle: feature.terminalTitle(for: session),
                    isActive: isActive
                )
            }
            .foregroundStyle(isActive ? LitheTheme.primaryText : LitheTheme.secondaryText)
            .padding(.leading, 9)
            .padding(.trailing, 5)
            .frame(height: 26)
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
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close \(feature.terminalTitle(for: session))")
        }
        .background(isActive ? LitheTheme.subtleSelection : .clear)
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(isActive ? LitheTheme.inputFocusBorder : .clear, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
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
        .lithePointer()
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

private struct TerminalStatusView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 5) {
                Circle()
                    .fill(session.isRunning ? Color.green : LitheTheme.secondaryText)
                    .frame(width: 6, height: 6)

                Text(session.displayTitle)
                    .lineLimit(1)

                if let directory = session.displayDirectory {
                    Text(directory)
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .lineLimit(1)
                }

                if let exitCode = session.lastExitCode {
                    Text("Exit \(exitCode)")
                        .foregroundStyle(exitCode == 0 ? Color.green : Color.orange)
                }

                if let elapsed = session.elapsedDescription(at: context.date) {
                    Text(elapsed)
                        .monospacedDigit()
                        .foregroundStyle(LitheTheme.tertiaryText)
                }
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(LitheTheme.secondaryText)
            .lineLimit(1)
            .frame(maxWidth: 240, alignment: .trailing)
            .help("Command-click a file path or URL to open it")
        }
    }
}

private struct TerminalToolTabTitle: View {
    @ObservedObject var session: TerminalSession
    let fallbackTitle: String
    let isActive: Bool

    var body: some View {
        Text(session.processTitle.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle)
            .font(.system(size: 11.5, weight: isActive ? .semibold : .medium))
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
