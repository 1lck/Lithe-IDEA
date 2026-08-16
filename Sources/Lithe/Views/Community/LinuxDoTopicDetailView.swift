import SwiftUI

struct LinuxDoTopicDetailView: View {
    let topic: RustCoreBridge.DiscourseTopicResponse
    @ObservedObject var feature: DiscourseCommunityFeatureModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                topicHeader
                ForEach(topic.posts) { post in
                    LinuxDoPostView(post: post)
                }
            }
            .padding(12)
        }
        .background(LitheTheme.sidebar)
    }

    private var topicHeader: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(topic.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(LitheTheme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Label("\(topic.posts.count) posts", systemImage: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer()
                Button {
                    feature.openTopic(id: topic.id, slug: topic.slug)
                } label: {
                    Label("Open in Browser", systemImage: "arrow.up.right")
                }
                .buttonStyle(.borderless)
                .help("Open this topic on linux.do")
            }
        }
        .padding(.bottom, 2)
    }
}

private struct LinuxDoPostView: View {
    let post: RustCoreBridge.DiscoursePost

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Text(LinuxDoCommunityFormatting.initials(post.name ?? post.username))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(LitheTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(LitheTheme.subtleSelection)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(post.name ?? post.username)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                    HStack(spacing: 4) {
                        Text("@\(post.username)")
                        if let date = LinuxDoCommunityFormatting.relativeDate(post.createdAt) {
                            Text("·")
                            Text(date)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(LitheTheme.tertiaryText)
                }
                Spacer()
                Text("#\(post.postNumber)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(LitheTheme.tertiaryText)
            }

            Text(LinuxDoCommunityFormatting.plainText(post.cooked))
                .font(.body)
                .foregroundStyle(LitheTheme.primaryText)
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if post.replyCount > 0 || post.reads > 0 {
                HStack(spacing: 12) {
                    if post.replyCount > 0 {
                        Label("\(post.replyCount)", systemImage: "arrowshape.turn.up.left")
                            .accessibilityLabel("\(post.replyCount) replies")
                    }
                    if post.reads > 0 {
                        Label(LinuxDoCommunityFormatting.compactNumber(post.reads), systemImage: "eye")
                            .accessibilityLabel("\(post.reads) reads")
                    }
                }
                .font(.caption2)
                .foregroundStyle(LitheTheme.tertiaryText)
            }
        }
        .padding(12)
        .background(LitheTheme.editor)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(LitheTheme.panelBorder, lineWidth: 0.5)
        }
    }
}
