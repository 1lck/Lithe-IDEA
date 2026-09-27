import SwiftUI
import LitheAgentConversationModule

struct AgentFileReferenceList: View {
    let files: [AgentFileReference]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(files) { file in
                    HStack(spacing: 5) {
                        Image(systemName: "doc")
                        Text(file.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160)
                        Button { onRemove(file.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(format: String(localized: "Remove file %@"), file.name))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(AgentPanelStyle.text)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(AgentPanelStyle.context, in: RoundedRectangle(cornerRadius: 5))
                    .help(file.url.path)
                }
            }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
        .frame(height: 34)
    }
}
