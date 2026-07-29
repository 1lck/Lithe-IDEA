import SwiftUI

struct DiffReviewView: View {
    @EnvironmentObject private var model: AppModel
    let change: GitChange

    var body: some View {
        VStack(spacing: 0) {
            diffHeader
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            columnHeader
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if model.diffRows.isEmpty {
                VStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Loading diff…")
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.diffRows) { row in
                            DiffRowView(row: row)
                        }
                    }
                    .frame(minWidth: 900)
                }
            }
        }
        .background(LitheTheme.editor)
    }

    private var diffHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: "doc.text")
                .foregroundStyle(LitheTheme.secondaryText)
            Text(change.path)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)
            Text(change.isStaged && !change.hasWorkingTreeChange ? "STAGED" : "WORKING TREE")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(change.isStaged ? LitheTheme.success : LitheTheme.warning)
            Spacer()

            if change.isStaged && !change.hasWorkingTreeChange {
                Button("Unstage") {
                    Task { await model.unstageSelectedChange() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button("Discard") {
                    model.requestDiscardSelectedChange()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Stage File") {
                    Task { await model.stageSelectedChange() }
                }
                .buttonStyle(.borderedProminent)
                .tint(LitheTheme.accent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(LitheTheme.sidebar)
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Repository version")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 48)
            Rectangle().fill(LitheTheme.divider).frame(width: 1)
            Text("Working version")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 48)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(LitheTheme.secondaryText)
        .frame(height: 28)
        .background(LitheTheme.window)
    }
}

private struct DiffRowView: View {
    let row: DiffRow

    var body: some View {
        if row.kind == .information {
            HStack {
                Text(row.left ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(red: 0.48, green: 0.68, blue: 0.91))
                    .padding(.leading, 10)
                Spacer()
            }
            .frame(height: 25)
            .background(Color(red: 0.13, green: 0.19, blue: 0.27))
        } else {
            HStack(spacing: 0) {
                diffCell(number: row.oldLine, text: row.left, isLeft: true)
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                diffCell(number: row.newLine, text: row.right, isLeft: false)
            }
            .frame(height: 23)
        }
    }

    private func diffCell(number: Int?, text: String?, isLeft: Bool) -> some View {
        HStack(spacing: 0) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 42, alignment: .trailing)
                .padding(.trailing, 7)
            Text(text ?? "")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(text == nil ? .clear : LitheTheme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .lineLimit(1)
        }
        .background(backgroundColor(isLeft: isLeft, hasText: text != nil))
        .frame(maxWidth: .infinity)
    }

    private func backgroundColor(isLeft: Bool, hasText: Bool) -> Color {
        guard hasText else { return Color.black.opacity(0.10) }
        switch row.kind {
        case .changed:
            return isLeft ? Color.red.opacity(0.16) : Color.green.opacity(0.15)
        case .removal:
            return isLeft ? Color.red.opacity(0.18) : .clear
        case .addition:
            return isLeft ? .clear : Color.green.opacity(0.17)
        default:
            return .clear
        }
    }
}
