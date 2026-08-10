import AppKit
import SwiftUI

struct CloneRepositoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var remoteURL = ""
    @State private var parentFolder = NSHomeDirectory()
    @State private var folderName = ""
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case remote
        case folder
    }

    private var destinationURL: URL {
        let expandedParent = (parentFolder as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedParent)
            .appendingPathComponent(folderName.trimmingCharacters(in: .whitespacesAndNewlines))
            .standardizedFileURL
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            VStack(alignment: .leading, spacing: 18) {
                field("Repository URL") {
                    TextField("https://github.com/example/project.git", text: $remoteURL)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .remote)
                        .onSubmit { focusedField = .folder }
                }

                field("Destination folder") {
                    HStack(spacing: 7) {
                        TextField("~/Projects", text: $parentFolder)
                            .textFieldStyle(.plain)
                        Button("Choose…") {
                            chooseParentFolder()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .lithePointer()
                    }
                }

                field("Folder name") {
                    TextField("project-name", text: $folderName)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .folder)
                }

                Text("Lithe will clone the repository into (destinationDescription).")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(2)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(LitheTheme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            footer
        }
        .frame(width: 560, height: 360)
        .background(LitheTheme.window)
        .preferredColorScheme(.dark)
        .onAppear {
            focusedField = .remote
        }
        .onChange(of: remoteURL) { _, value in
            guard folderName.isEmpty else { return }
            folderName = defaultFolderName(from: value)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            LitheIDEAIcon(
                resourcePath: "toolwindows/toolWindowVcs.svg",
                size: 16,
                fallbackSystemImage: "point.3.connected.trianglepath.dotted"
            )
            Text("Clone Repository")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .litheIconButton()
            .disabled(model.isCloningRepository)
            .help("Cancel")
        }
        .foregroundStyle(LitheTheme.primaryText)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(LitheTheme.toolHeader)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .lithePointer()
            .disabled(model.isCloningRepository)

            Button {
                Task {
                    errorMessage = await model.cloneRepository(
                        remote: remoteURL,
                        destination: destinationURL
                    )
                    if errorMessage == nil {
                        dismiss()
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    if model.isCloningRepository {
                        ProgressView().controlSize(.small)
                    }
                    Text("Clone")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(LitheTheme.accent)
            .lithePointer()
            .disabled(model.isCloningRepository || !canClone)
        }
        .padding(14)
        .background(LitheTheme.toolHeader)
    }

    private func field<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            content()
                .font(.system(size: 12.5))
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(LitheTheme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                        .stroke(LitheTheme.inputBorder, lineWidth: 1)
                }
        }
    }

    private var canClone: Bool {
        !remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !parentFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var destinationDescription: String {
        destinationURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func chooseParentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        parentFolder = url.path
    }

    private func defaultFolderName(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastComponent = trimmed
            .split(separator: "/")
            .last
            .map(String.init) ?? ""
        let name = lastComponent.hasSuffix(".git")
            ? String(lastComponent.dropLast(4))
            : lastComponent
        return name.isEmpty ? "project" : name
    }
}
