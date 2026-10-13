// Adapted from IntelliJ GitRefManager, SimpleRefGroup and LabelPainter.
// Copyright 2000-2024 JetBrains s.r.o. and contributors. Apache-2.0.
// See Resources/GitGraph/NOTICE.txt.
import AppKit
import LitheGitModule

/// IDEA's default compact reference display. The original names remain intact
/// for hover help; width-dependent shortening belongs only to the renderer.
struct GitGraphReferenceGroup: Equatable, Sendable {
    let title: String
    let labels: [GitGraphLabel]
    let iconKinds: [GitGraphReferenceKind]
    let tooltip: String

    init(labels: [GitGraphLabel], references: [GitReference] = []) {
        let current = references.first { $0.kind == .local && $0.isCurrent }?.shortName
        func rank(_ label: GitGraphLabel) -> Int {
            switch label.kind {
            case .head: 0
            case .branch: label.title == current ? 1 : ["main", "master"].contains(label.title) ? 2 : 4
            case .remote: ["origin/main", "origin/master"].contains(label.title) ? 3 : 5
            case .tag: 6
            }
        }
        let sorted = labels.sorted {
            rank($0) == rank($1)
                ? GitGraphHeadOrdering.naturalCompare(Array($0.title.utf16), Array($1.title.utf16)) < 0
                : rank($0) < rank($1)
        }
        let locals = sorted.filter { $0.kind == .branch }
        let remotes = sorted.filter { $0.kind == .remote }
        var tracked: [(local: GitGraphLabel, remote: GitGraphLabel, name: String)] = []
        for local in locals {
            let upstream = references.first { $0.kind == .local && $0.shortName == local.title }?.upstreamShortName
            if let remote = remotes.first(where: { $0.title == upstream })
                ?? remotes.first(where: { $0.title.split(separator: "/", maxSplits: 1).last.map(String.init) == local.title }) {
                let remoteName = remote.title.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
                tracked.append((local, remote, remoteName + " & " + local.title))
            }
        }
        let paired = Set(tracked.flatMap { [$0.local.id, $0.remote.id] })
        let unpaired = sorted.filter { $0.kind != .head && !paired.contains($0.id) }
        let currentLabel = unpaired.first { $0.kind == .branch && $0.title == current }
        // A detached HEAD remains explicit. Attached HEAD adds a yellow icon
        // to the branch group instead of consuming a separate text label.
        if let currentLabel {
            title = currentLabel.title
        } else if let tracked = tracked.first {
            title = tracked.name
        } else if let first = unpaired.first {
            title = first.kind == .tag ? "" : first.title
        } else {
            title = sorted.contains { $0.kind == .head } ? "HEAD" : ""
        }
        self.labels = sorted
        tooltip = sorted.map(\.title).joined(separator: "\n")
        var kinds: [GitGraphReferenceKind] = []
        for label in sorted where kinds.filter({ $0 == label.kind }).count < 2 { kinds.append(label.kind) }
        iconKinds = kinds
    }

    func iconWidth(height: CGFloat) -> CGFloat {
        labels.isEmpty ? 0 : (height + CGFloat(iconKinds.count - 1) * height / 6.25 * 2).rounded()
    }

    func shortenedTitle(availableWidth: CGFloat, font: NSFont) -> String {
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        guard title.count > 22, width(title) > availableWidth else { return title }
        var result = title
        if let slash = result.firstIndex(of: "/"), result.distance(from: result.startIndex, to: slash) > 2 {
            result = ".." + result[slash...]
        }
        // VcsLogUiUtil keeps at least 22 characters; the enclosing column
        // clips only when even that minimum cannot fit.
        if availableWidth > 0, width(result) <= availableWidth { return result }
        while result.count > 22 {
            if result.last == "…" { result.removeLast() }
            result.removeLast()
            let candidate = result + "…"
            if availableWidth > 0, width(candidate) <= availableWidth { return candidate }
        }
        return result.count >= 22 ? String(result.prefix(21)) + "…" : result
    }
}
