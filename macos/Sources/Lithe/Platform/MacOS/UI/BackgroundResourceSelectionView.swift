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
    private(set) var selectedIDs: Set<String>
    private let document: ResourceListDocument

    init(resources: [BackgroundResourceCandidate]) {
        self.resources = resources
        selectedIDs = Set(resources.map(\.id))
        document = ResourceListDocument(resources: resources, width: Self.contentWidth - 24)
        super.init(frame: .zero)
        document.isSelected = { [weak self] in self?.selectedIDs.contains($0) == true }
        document.onToggle = { [weak self] id, selected in
            guard let self, self.selectedIDs.contains(id) != selected else { return }
            if selected { self.selectedIDs.insert(id) } else { self.selectedIDs.remove(id) }
            self.selectionChanged(changedIDs: [id])
        }
        scrollView.frame = NSRect(x: 0, y: 0, width: Self.contentWidth,
                                  height: min(document.frame.height, Self.maximumListHeight))
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

    private func selectionChanged(changedIDs: Set<String> = []) {
        let selected = selectedIDs.count
        selectionLabel.stringValue = String(format: L10n.string("%lld of %lld services selected"), selected, resources.count)
        selectAllButton.isEnabled = selected < resources.count
        deselectAllButton.isEnabled = selected > 0
        document.updateVisibleCheckboxes()
        document.notifyAccessibilitySelectionChanged(for: changedIDs)
    }

    @objc private func selectAllResources() {
        let changedIDs = Set(resources.map(\.id)).subtracting(selectedIDs)
        selectedIDs.formUnion(changedIDs)
        selectionChanged(changedIDs: changedIDs)
    }

    @objc private func deselectAllResources() {
        let changedIDs = selectedIDs
        selectedIDs.removeAll()
        selectionChanged(changedIDs: changedIDs)
    }
}

/// TextKit caches the fixed-width layout and draws only visible glyphs, even
/// when one command spans many screens. Only visible checkbox anchors own views.
@MainActor
private final class ResourceListDocument: NSTextView {
    private struct Anchor {
        let id: String
        let name: String
        let y: CGFloat
    }

    var isSelected: (String) -> Bool = { _ in false }
    var onToggle: (String, Bool) -> Void = { _, _ in }
    private var anchors: [Anchor] = []
    private var checkboxes: [Int: ResourceCheckbox] = [:]
    private var accessibilityCheckboxes: [String: ResourceCheckboxAccessibilityElement] = [:]
    private var scrollObservation: NSObjectProtocol?

    init(resources: [BackgroundResourceCandidate], width: CGFloat) {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width - 36, height: .greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 16), textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainerInset = NSSize(width: 36, height: 8)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        setAccessibilityLabel(L10n.string("Background Services"))

        let text = NSMutableAttributedString()
        var starts: [Int] = []
        for resource in resources {
            starts.append(text.length)
            var paragraphs: [(String, NSFont, NSColor)] = [
                (resource.name, LitheTheme.uiNSFont(size: 12.5, weight: .semibold), .labelColor)
            ]
            if !resource.detail.isEmpty && resource.detail != resource.name {
                paragraphs.append((resource.detail, LitheTheme.editorFont(size: 12), .labelColor))
            }
            var metadata = resource.listeningPorts.isEmpty ? [] : [String(format: L10n.string("ports %@"), resource.listeningPorts.map(String.init).joined(separator: ", "))]
            if resource.processIDs.count > 1 {
                metadata.append(String(format: L10n.string("%lld processes"), resource.processIDs.count))
            }
            if !metadata.isEmpty {
                paragraphs.append((metadata.joined(separator: " · "), LitheTheme.uiNSFont(size: 11), .secondaryLabelColor))
            }
            for (index, paragraph) in paragraphs.enumerated() {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byCharWrapping
                style.paragraphSpacing = index == paragraphs.count - 1 ? 12 : 4
                text.append(NSAttributedString(string: paragraph.0 + "\n", attributes: [
                    .font: paragraph.1, .foregroundColor: paragraph.2, .paragraphStyle: style
                ]))
            }
        }
        storage.setAttributedString(text)
        // Prepare once before showing the alert; scrolling must not measure
        // commands or rebuild text storage to discover row positions.
        manager.ensureLayout(for: container)
        anchors = zip(resources, starts).map { resource, start in
            let glyph = manager.glyphIndexForCharacter(at: start)
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return Anchor(id: resource.id, name: resource.name, y: line.minY + textContainerInset.height)
        }
        frame.size.height = max(16, ceil(manager.usedRect(for: container).maxY) + 16)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) }
        scrollObservation = nil
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            scrollObservation = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.updateVisibleCheckboxes() } }
        }
        updateVisibleCheckboxes()
    }

    override func accessibilityChildren() -> [Any]? {
        let children = (super.accessibilityChildren() ?? []).filter { !($0 is ResourceCheckbox) }
        return children + anchors.enumerated().map { index, anchor in
            if let existing = accessibilityCheckboxes[anchor.id] { return existing }
            let element = ResourceCheckboxAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.checkBox)
            element.setAccessibilityLabel(anchor.name)
            element.isSelected = { [weak self] in self?.isSelected(anchor.id) == true }
            element.setAccessibilityFrameInParentSpace(NSRect(x: 8, y: anchor.y, width: 20, height: 20))
            element.onPress = { [weak self] in
                guard let self else { return }
                self.scrollToVisible(NSRect(x: 0, y: self.anchors[index].y, width: 20, height: 20))
                self.onToggle(anchor.id, !self.isSelected(anchor.id))
            }
            accessibilityCheckboxes[anchor.id] = element
            return element
        }
    }

    func notifyAccessibilitySelectionChanged(for ids: Set<String>) {
        // Notify the same objects already handed to assistive technology;
        // scrolling or selection changes must not create offscreen controls.
        for id in ids.sorted() {
            if let element = accessibilityCheckboxes[id] {
                NSAccessibility.post(element: element, notification: .valueChanged)
            }
        }
    }

    private func focusCheckbox(at index: Int) -> Bool {
        guard anchors.indices.contains(index), let window else { return false }
        scrollToVisible(NSRect(x: 0, y: anchors[index].y, width: 20, height: 20))
        updateVisibleCheckboxes()
        guard let checkbox = checkboxes[index] else { return false }
        return window.makeFirstResponder(checkbox)
    }

    func updateVisibleCheckboxes() {
        let viewport = visibleRect.insetBy(dx: 0, dy: -20)
        var low = 0, high = anchors.count
        while low < high {
            let mid = (low + high) / 2
            if anchors[mid].y + 20 < viewport.minY { low = mid + 1 } else { high = mid }
        }
        let first = low
        while low < anchors.count, anchors[low].y <= viewport.maxY { low += 1 }
        let visible = first..<low
        for index in Array(checkboxes.keys) where !visible.contains(index) {
            checkboxes.removeValue(forKey: index)?.removeFromSuperview()
        }
        for index in visible {
            let anchor = anchors[index]
            let checkbox: ResourceCheckbox
            if let existing = checkboxes[index] {
                checkbox = existing
            } else {
                checkbox = ResourceCheckbox(checkboxWithTitle: "", target: self, action: #selector(toggleResource))
                checkbox.tag = index
                checkbox.frame = NSRect(x: 8, y: anchor.y, width: 20, height: 20)
                checkbox.setAccessibilityLabel(anchor.name)
                checkbox.onMove = { [weak self] offset in self?.focusCheckbox(at: index + offset) == true }
                addSubview(checkbox)
                checkboxes[index] = checkbox
            }
            checkbox.state = isSelected(anchor.id) ? .on : .off
        }
    }

    @objc private func toggleResource(_ sender: NSButton) {
        onToggle(anchors[sender.tag].id, sender.state == .on)
    }
}

private final class ResourceCheckbox: NSButton {
    var onMove: ((Int) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let offset: Int
        switch event.keyCode {
        case 48: offset = event.modifierFlags.contains(.shift) ? -1 : 1
        case 125: offset = 1
        case 126: offset = -1
        default: super.keyDown(with: event); return
        }
        if onMove?(offset) != true { super.keyDown(with: event) }
    }
}

private final class ResourceCheckboxAccessibilityElement: NSAccessibilityElement {
    var isSelected: (() -> Bool)?
    var onPress: (() -> Void)?
    override func accessibilityValue() -> Any? { isSelected?() == true ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }
}
