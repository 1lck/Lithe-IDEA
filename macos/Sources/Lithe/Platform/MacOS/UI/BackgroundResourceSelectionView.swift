import LitheModuleAPI
import AppKit

// Note: .agents/notes/implemented/bug-fix/2026-10-21-background-service-exit-selection.md

/// Bounded, selectable command details for the background-service exit alert.
/// Selection belongs to this confirmation; no process is changed until it is accepted.
@MainActor
final class BackgroundResourceSelectionView: NSView {
    static let contentWidth: CGFloat = 520
    static let maximumListHeight: CGFloat = 260

    let resources: [BackgroundResourceCandidate]
    let scrollView = NSScrollView()
    let selectAllButton = NSButton(title: L10n.string("Select All"), target: nil, action: nil)
    let deselectAllButton = NSButton(title: L10n.string("Deselect All"), target: nil, action: nil)
    let selectionLabel = NSTextField(labelWithString: "")
    let rememberCheckbox = NSButton(
        checkboxWithTitle: L10n.string("Remember my choice for these kinds of services"),
        target: nil, action: nil
    )
    private var checkboxes: [NSButton] = []

    var selectedIDs: Set<String> {
        Set(zip(resources, checkboxes).filter { $0.1.state == .on }.map(\.0.id))
    }

    init(resources: [BackgroundResourceCandidate]) {
        self.resources = resources
        super.init(frame: .zero)
        let document = ResourceListDocument(frame: .zero)
        let rowWidth = Self.contentWidth - 24
        var y: CGFloat = 8
        for resource in resources {
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(selectionChanged))
            checkbox.state = .on
            checkbox.setAccessibilityLabel(resource.name)
            checkbox.frame = NSRect(x: 8, y: y, width: 20, height: 20)
            document.addSubview(checkbox)
            checkboxes.append(checkbox)
            let textWidth = rowWidth - 36
            let title = Self.label(resource.name, width: textWidth, font: LitheTheme.uiNSFont(size: 12.5, weight: .semibold))
            title.frame.origin = NSPoint(x: 36, y: y)
            document.addSubview(title)
            var height = max(20, title.frame.height)
            if !resource.detail.isEmpty && resource.detail != resource.name {
                let detail = Self.label(resource.detail, width: textWidth, font: LitheTheme.editorFont(size: 12))
                detail.frame.origin = NSPoint(x: 36, y: y + height + 4)
                document.addSubview(detail)
                height += 4 + detail.frame.height
            }
            var metadata = resource.listeningPorts.isEmpty ? [] : [String(format: L10n.string("ports %@"), resource.listeningPorts.map(String.init).joined(separator: ", "))]
            if resource.processIDs.count > 1 {
                metadata.append(String(format: L10n.string("%lld processes"), resource.processIDs.count))
            }
            if !metadata.isEmpty {
                let label = Self.label(metadata.joined(separator: " · "), width: textWidth, font: LitheTheme.uiNSFont(size: 11))
                label.textColor = .secondaryLabelColor
                label.frame.origin = NSPoint(x: 36, y: y + height + 4)
                document.addSubview(label)
                height += 4 + label.frame.height
            }
            y += height + 12
        }
        document.frame = NSRect(x: 0, y: 0, width: rowWidth, height: y)
        scrollView.frame = NSRect(x: 0, y: 0, width: Self.contentWidth, height: min(y, Self.maximumListHeight))
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller = LitheScrollViewChrome.CompactScroller()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = document
        scrollView.setAccessibilityLabel(L10n.string("Background Services"))

        selectAllButton.target = self
        selectAllButton.action = #selector(selectAllResources)
        deselectAllButton.target = self
        deselectAllButton.action = #selector(deselectAllResources)
        for button in [selectAllButton, deselectAllButton] { button.bezelStyle = .rounded }
        let header = NSStackView(views: [selectionLabel, selectAllButton, deselectAllButton])
        header.orientation = .horizontal
        header.spacing = 8
        header.distribution = .fill
        selectionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [header, scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        if resources.contains(where: { $0.recognizerID != nil }) { stack.addArrangedSubview(rememberCheckbox) }
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            scrollView.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            scrollView.heightAnchor.constraint(equalToConstant: scrollView.frame.height)
        ])
        selectionChanged()
        frame.size = stack.fittingSize
    }

    required init?(coder: NSCoder) { nil }

    private static func label(_ text: String, width: CGFloat, font: NSFont) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.isSelectable = true
        field.lineBreakMode = .byCharWrapping
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = width
        field.frame = NSRect(x: 0, y: 0, width: width, height: 0)
        let height = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 20
        field.frame.size.height = ceil(height)
        return field
    }

    @objc private func selectionChanged() {
        let selected = selectedIDs.count
        selectionLabel.stringValue = String(format: L10n.string("%lld of %lld services selected"), selected, resources.count)
        selectAllButton.isEnabled = selected < resources.count
        deselectAllButton.isEnabled = selected > 0
    }

    @objc private func selectAllResources() {
        checkboxes.forEach { $0.state = .on }
        selectionChanged()
    }

    @objc private func deselectAllResources() {
        checkboxes.forEach { $0.state = .off }
        selectionChanged()
    }
}

private final class ResourceListDocument: NSView {
    override var isFlipped: Bool { true }
}
