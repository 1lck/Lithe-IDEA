import AppKit
import SwiftUI

struct CloneRepositoryView: View {
    @EnvironmentObject private var model: AppModel

    @State private var remoteURL = ""
    @State private var parentFolder = NSHomeDirectory()
    @State private var folderName = ""
    @State private var errorMessage: String?
    @FocusState private var remoteFocused: Bool
    @FocusState private var folderFocused: Bool

    private var destinationURL: URL {
        let expandedParent = (parentFolder as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedParent)
            .appendingPathComponent(folderName.trimmingCharacters(in: .whitespacesAndNewlines))
            .standardizedFileURL
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                LitheFormField(title: Text("Repository URL")) {
                    LitheTextField("https://github.com/example/project.git", text: $remoteURL, focus: $remoteFocused)
                        .onSubmit { folderFocused = true }
                }

                LitheFormField(title: Text("Destination folder")) {
                    HStack(spacing: 7) {
                        LitheTextField("~/Projects", text: $parentFolder)
                        Button("Choose…") {
                            chooseParentFolder()
                        }
                        .buttonStyle(LitheActionButtonStyle())
                    }
                }

                LitheFormField(title: Text("Folder name")) {
                    LitheTextField("project-name", text: $folderName, focus: $folderFocused)
                }

                Text("Lithe will clone the repository into \(destinationDescription).")
                    .font(LitheTheme.settingsFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(2)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(LitheTheme.settingsFont)
                        .foregroundStyle(LitheTheme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            footer
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(LitheTheme.window)
        .onAppear {
            remoteFocused = true
        }
        .onChange(of: remoteURL) { value in
            guard folderName.isEmpty else { return }
            folderName = defaultFolderName(from: value)
        }
    }

    private var footer: some View {
        HStack(spacing: LitheTheme.ActionButton.spacing) {
            Spacer()
            Button("Cancel") {
                model.workbenchFeature.isCloneRepositoryPresented = false
            }
            .buttonStyle(LitheActionButtonStyle())
            .disabled(model.isCloningRepository)

            Button {
                Task {
                    errorMessage = await model.cloneRepository(
                        remote: remoteURL,
                        destination: destinationURL
                    )
                    if errorMessage == nil {
                        model.workbenchFeature.isCloneRepositoryPresented = false
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
            .buttonStyle(LitheActionButtonStyle(isPrimary: true))
            .disabled(model.isCloningRepository || !canClone)
        }
        .padding(14)
        .background(LitheTheme.toolHeader)
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
        if let path = LitheDirectoryPicker.choose(startingAt: parentFolder) {
            parentFolder = path
        }
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
