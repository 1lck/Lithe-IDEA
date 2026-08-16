import SwiftUI

struct LinuxDoTopicListView: View {
    @ObservedObject var feature: DiscourseCommunityFeatureModel
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            controls
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            if feature.topics.isEmpty {
                emptyState
            } else {
                topicList
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("Topic feed", selection: $feature.selectedFeed) {
                Label("Latest", systemImage: "clock").tag(DiscourseCommunityFeatureModel.Feed.latest)
                Label("Top", systemImage: "flame").tag(DiscourseCommunityFeatureModel.Feed.top)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: feature.selectedFeed) { _ in
                Task { await feature.refresh() }
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(searchIsFocused ? LitheTheme.accent : LitheTheme.tertiaryText)
                TextField("Search discussions", text: $feature.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($searchIsFocused)
                    .onSubmit { Task { await feature.search() } }
                if !feature.searchQuery.isEmpty {
                    Button {
                        feature.searchQuery = ""
                        Task { await feature.refresh() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(LitheTheme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(searchIsFocused ? LitheTheme.inputFocusBorder : LitheTheme.inputBorder)
            }
        }
        .padding(10)
        .background(LitheTheme.toolHeader)
    }

    private var topicList: some View {
        List(feature.topics) { topic in
            Button {
                Task { await feature.selectTopic(topic) }
            } label: {
                LinuxDoTopicRow(
                    topic: topic,
                    categoryName: categoryName(for: topic.categoryId)
                )
            }
            .buttonStyle(.plain)
            .lithePointer()
            .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityHint("Opens the topic")
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(LitheTheme.sidebar)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: feature.searchQuery.isEmpty ? "tray" : "magnifyingglass")
                .font(.title2)
                .foregroundStyle(LitheTheme.tertiaryText)
            Text(feature.searchQuery.isEmpty ? "No topics yet" : "No matching discussions")
                .font(.headline)
            Text(feature.searchQuery.isEmpty
                ? "Refresh to check for new discussions."
                : "Try a broader phrase or clear the search.")
                .font(.subheadline)
                .foregroundStyle(LitheTheme.secondaryText)
                .multilineTextAlignment(.center)
            if !feature.searchQuery.isEmpty {
                Button("Clear Search") {
                    feature.searchQuery = ""
                    Task { await feature.refresh() }
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func categoryName(for id: UInt64?) -> String? {
        guard let id else { return nil }
        return feature.categories.first(where: { $0.id == id })?.name
    }
}

private struct LinuxDoTopicRow: View {
    let topic: RustCoreBridge.DiscourseTopicSummary
    let categoryName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if topic.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(LitheTheme.accent)
                        .accessibilityLabel("Pinned")
                }
                Text(topic.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                if let categoryName {
                    Text(categoryName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(LitheTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(LitheTheme.subtleSelection)
                        .clipShape(Capsule())
                        .lineLimit(1)
                }
                if let date = LinuxDoCommunityFormatting.relativeDate(topic.lastPostedAt) {
                    if categoryName != nil {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(LitheTheme.tertiaryText)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                metadata("bubble.left", topic.replyCount, label: "replies")
                metadata("eye", topic.views, label: "views")
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(LitheTheme.editor)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(LitheTheme.panelBorder, lineWidth: 0.5)
        }
        .litheRowHover(isActive: false, cornerRadius: 9)
    }

    private func metadata(_ icon: String, _ value: UInt64, label: String) -> some View {
        Label(LinuxDoCommunityFormatting.compactNumber(value), systemImage: icon)
            .font(.caption2)
            .foregroundStyle(LitheTheme.tertiaryText)
            .labelStyle(.titleAndIcon)
            .accessibilityLabel("\(value) \(label)")
    }
}
