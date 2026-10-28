import AppKit
import LitheCoreContracts
import LitheDebugModule
import SwiftUI

/// Keeps the Debug tool window's tab in step with the disassembly model. The model opens by
/// itself on a frame without source, and a nested `ObservableObject` is not observed through
/// the feature model, so this watches it directly.
struct DebugDisassemblyPresentationObserver: View {
    @ObservedObject var disassembly: GenericDebugDisassemblyModel
    let onChange: (Bool) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: disassembly.isPresented) { onChange($0) }
            .allowsHitTesting(false)
    }
}

/// Hands whether steps currently move by instruction to a view that has to reflect it, such
/// as the step buttons' tooltips, without making the whole Debug panel observe the model.
struct DebugSteppingGranularityReader<Content: View>: View {
    @ObservedObject var disassembly: GenericDebugDisassemblyModel
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(disassembly.stepsByInstruction)
    }
}

/// The instructions around the selected frame's instruction pointer, with a gutter for
/// instruction breakpoints. Addresses are shown exactly as the adapter wrote them.
struct GenericDebugDisassemblyView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var disassembly: GenericDebugDisassemblyModel
    let readMemory: (String) -> Void

    private enum Item: Identifiable {
        case symbol(id: String, name: String)
        case instruction(DebugDisassembledInstruction)

        var id: String {
            switch self {
            case .symbol(let id, _): "symbol:" + id
            case .instruction(let instruction): instruction.address
            }
        }
    }

    private static let fontSize: CGFloat = 12
    private static let rowHeight: CGFloat = 20
    private static let gutterWidth: CGFloat = 22

    private var items: [Item] {
        var result: [Item] = []
        var lastSymbol: String?
        for instruction in disassembly.rows {
            if let symbol = instruction.symbol, !symbol.isEmpty, symbol != lastSymbol {
                result.append(.symbol(id: instruction.address, name: symbol))
            }
            if let symbol = instruction.symbol, !symbol.isEmpty { lastSymbol = symbol }
            result.append(.instruction(instruction))
        }
        return result
    }

    private var characterWidth: CGFloat {
        LitheTheme.editorFont(size: Self.fontSize).maximumAdvancement.width
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !disassembly.rows.isEmpty,
               let failure = disassembly.loadFailure, let direction = disassembly.failedDirection {
                HStack {
                    Text(verbatim: failure).foregroundStyle(LitheTheme.error).lineLimit(1)
                    Button("Retry") { disassembly.loadMore(direction) }
                        .buttonStyle(.litheNoPress)
                }
                .font(LitheTheme.uiFont(size: 12))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Self.rowHeight)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Text("Disassembly")
                .font(LitheTheme.uiFont(size: 13, weight: .regular))
                .foregroundStyle(LitheTheme.Tree.text)
            if disassembly.isLoading {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 0)
            if disassembly.stepsByInstruction {
                Text("Stepping by instruction")
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.accent)
            } else if disassembly.isPresented {
                // Without the adapter's help a step would run a whole source line, which looks
                // like a bug in the instruction listing, so say so.
                Text("This adapter cannot step by instruction; steps still move by line")
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.warning)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: LitheTheme.Debugger.inspectorHeaderHeight)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    @ViewBuilder
    private var content: some View {
        if let failure = disassembly.loadFailure, disassembly.rows.isEmpty {
            failureText(failure)
        } else if disassembly.rows.isEmpty {
            LitheToolWindowStatusText(
                disassembly.isLoading ? "Loading instructions…" : "Select a frame to see its instructions"
            )
        } else {
            list
        }
    }

    private func failureText(_ message: String) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Text(verbatim: message)
                .font(LitheTheme.uiFont(size: 13))
                .foregroundStyle(LitheTheme.error)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button("Retry") { disassembly.reload() }
                .buttonStyle(.litheNoPress)
                .font(LitheTheme.uiFont(size: 13))
                .foregroundStyle(LitheTheme.Debugger.value)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        let width = characterWidth
        let addressColumn = CGFloat(disassembly.rows.map(\.address.count).max() ?? 0) * width
        let bytesColumn = CGFloat(disassembly.rows.compactMap { $0.instructionBytes?.count }.max() ?? 0) * width
        let visibleItems = items
        let ids = visibleItems.map(\.id)
        let font = LitheTheme.editorFont(size: Self.fontSize)
        let textWidth = disassembly.rows.map { instruction in
            (instruction.instruction as NSString).size(withAttributes: [.font: font]).width
                + (sourceLocation(instruction).map { ($0 as NSString).size(withAttributes: [.font: font]).width + 10 } ?? 0)
        }.max() ?? 0
        let symbolWidth = disassembly.rows.compactMap(\.symbol).map {
            (($0 + ":") as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        let contentWidth = Self.gutterWidth + 20 + max(symbolWidth,
            addressColumn + 10 + (bytesColumn > 0 ? bytesColumn + 10 : 0) + textWidth)
        return GeometryReader { viewport in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleItems) { item in
                        switch item {
                        case .symbol(_, let name):
                            symbolRow(name)
                        case .instruction(let instruction):
                            instructionRow(instruction, addressColumn: addressColumn, bytesColumn: bytesColumn)
                        }
                    }
                }
                .frame(width: max(viewport.size.width, ceil(contentWidth)), alignment: .leading)
                .background(DebugDisassemblyViewport(
                    ids: ids,
                    currentID: disassembly.rows.first(where: { disassembly.isCurrent($0) })?.address,
                    rowHeight: Self.rowHeight,
                    loadMore: { disassembly.loadMore($0, automatically: true) }
                ))
                .litheScrollViewChrome()
            }
        }
    }

    private func symbolRow(_ name: String) -> some View {
        Text(verbatim: name + ":")
            .font(LitheTheme.uiFont(size: Self.fontSize, weight: .semibold, design: .monospaced))
            .foregroundStyle(LitheTheme.Tree.secondaryText)
            .padding(.leading, Self.gutterWidth + 10)
            .frame(height: Self.rowHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func instructionRow(
        _ instruction: DebugDisassembledInstruction,
        addressColumn: CGFloat,
        bytesColumn: CGFloat
    ) -> some View {
        let isCurrent = disassembly.isCurrent(instruction)
        let breakpoint = disassembly.breakpoint(at: instruction.address)
        return HStack(spacing: 10) {
            gutter(for: instruction.address, breakpoint: breakpoint, isCurrent: isCurrent)
            Text(verbatim: instruction.address)
                .foregroundStyle(LitheTheme.Tree.secondaryText)
                .frame(width: addressColumn, alignment: .leading)
            if bytesColumn > 0 {
                Text(verbatim: instruction.instructionBytes ?? "")
                    .foregroundStyle(LitheTheme.Tree.secondaryText)
                    .frame(width: bytesColumn, alignment: .leading)
            }
            // Natural width: inside a two-axis scroll view a flexible Text can be proposed no
            // width at all and collapse to nothing, which hid the mnemonic on every row.
            Text(verbatim: instruction.instruction)
                .foregroundStyle(LitheTheme.Tree.text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if let location = sourceLocation(instruction) {
                Text(verbatim: location)
                    .foregroundStyle(LitheTheme.Tree.secondaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
        }
        .font(LitheTheme.uiFont(size: Self.fontSize, design: .monospaced))
        .padding(.trailing, 10)
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? Color(nsColor: executionLineColor) : Color.clear)
        .id(instruction.address)
        .litheContextMenu {
            var menu: [LitheContextMenuItem] = []
            if disassembly.canSetInstructionBreakpoints {
                menu.append(
                    .action(
                        breakpoint == nil ? "Set Instruction Breakpoint" : "Remove Instruction Breakpoint",
                        action: { disassembly.toggleBreakpoint(at: instruction.address) }))
                menu.append(.separator)
            }
            if disassembly.canReadMemory {
                menu.append(
                    .action("Read Memory at Address", action: { readMemory(instruction.address) }))
            }
            menu.append(.action("Copy Address", action: { copy(instruction.address) }))
            menu.append(.action("Copy Instruction", action: { copy(instruction.instruction) }))
            return menu
        }
    }

    private func gutter(
        for address: String,
        breakpoint: GenericDebugInstructionBreakpoint?,
        isCurrent: Bool
    ) -> some View {
        Button {
            disassembly.toggleBreakpoint(at: address)
        } label: {
            ZStack {
                if let breakpoint {
                    LitheIDEAIcon(
                        resourcePath: LitheIcons.debuggerBreakpointAssetPath(
                            enabled: breakpoint.enabled, verified: breakpoint.verified, muted: false),
                        size: 13,
                        fallbackSystemImage: breakpoint.enabled ? "circle.fill" : "circle",
                        preservesOriginalColors: true
                    )
                } else if isCurrent {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(LitheTheme.uiFont(size: 9))
                        .foregroundStyle(LitheTheme.accent)
                }
            }
            .frame(width: Self.gutterWidth, height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .disabled(!disassembly.canSetInstructionBreakpoints)
        .help(breakpoint?.message.map { Text(verbatim: $0) } ?? Text("Toggle instruction breakpoint"))
        .accessibilityLabel("Toggle instruction breakpoint")
    }

    private func sourceLocation(_ instruction: DebugDisassembledInstruction) -> String? {
        guard let url = instruction.sourceURL else { return nil }
        guard let line = instruction.line, line > 0 else { return "; " + url.lastPathComponent }
        return "; \(url.lastPathComponent):\(line)"
    }

    private var executionLineColor: NSColor {
        CodeEditorPalette(isDark: colorScheme == .dark, theme: LitheTheme.activeTheme).executionLine
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

/// Native clip observation keeps high-frequency scrolling out of the feature model. Reveals
/// change only Y; a prepended page retains the old first row's exact viewport offset.
private struct DebugDisassemblyViewport: NSViewRepresentable {
    let ids: [String]
    let currentID: String?
    let rowHeight: CGFloat
    let loadMore: (GenericDebugDisassemblyModel.Direction) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.listingUpdatePending = ids != view.appliedIDs
        view.ids = ids
        view.currentID = currentID
        view.rowHeight = rowHeight
        view.loadMore = loadMore
        view.scheduleUpdate()
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach(); view.loadMore = nil }

    final class Probe: NSView {
        var ids: [String] = []
        var currentID: String?
        var rowHeight: CGFloat = 20
        var loadMore: ((GenericDebugDisassemblyModel.Direction) -> Void)?
        private weak var scroll: NSScrollView?
        private var observation: NSObjectProtocol?
        private var wheelMonitor: Any?
        fileprivate var appliedIDs: [String] = []
        var listingUpdatePending = false
        private var appliedCurrentID: String?
        private var previousY: CGFloat = 0
        private var adjusting = false
        private var scheduled = false
        private var pagingScheduled = false

        deinit {
            if let observation { NotificationCenter.default.removeObserver(observation) }
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        }

        func detach() {
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = nil
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil
            scroll = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() } else { scheduleUpdate() }
        }
        override func layout() { super.layout(); scheduleUpdate() }

        func scheduleUpdate() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.applyUpdate()
            }
        }

        private func applyUpdate() {
            guard window != nil, let enclosing = enclosingScrollView else { return }
            if scroll !== enclosing {
                if let observation { NotificationCenter.default.removeObserver(observation) }
                scroll = enclosing
                enclosing.contentView.postsBoundsChangedNotifications = true
                observation = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: enclosing.contentView, queue: .main
                ) { [weak self] _ in self?.didScroll() }
                if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
                wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, let scroll = self.scroll, event.window === self.window,
                          !self.listingUpdatePending,
                          scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) else { return event }
                    // At a mapping boundary the clip cannot move. Wheel intent must still
                    // request a page, including when the adapter returned a short first page.
                    let viewport = scroll.contentView.bounds
                    let margin = self.rowHeight * 8
                    if event.scrollingDeltaY > 0, viewport.minY <= margin { self.request(.before) }
                    else if event.scrollingDeltaY < 0,
                            viewport.maxY >= CGFloat(self.ids.count) * self.rowHeight - margin { self.request(.after) }
                    return event
                }
            }
            guard let scroll, let document = scroll.documentView else { return }
            adjusting = true
            defer { adjusting = false }
            scroll.layoutSubtreeIfNeeded()
            var origin = scroll.contentView.bounds.origin
            let height = scroll.contentView.bounds.height
            let listingChanged = ids != appliedIDs
            var replaced = false
            if listingChanged {
                let indices = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
                let sharedAnchor = appliedIDs.enumerated().first { indices[$0.element] != nil }
                replaced = sharedAnchor == nil
                if let anchor = sharedAnchor, let index = indices[anchor.element] {
                    // A leading symbol heading may disappear when the previous page has the
                    // same symbol; anchor a shared row, not necessarily the old first heading.
                    origin.y = previousY + CGFloat(index - anchor.offset) * rowHeight
                }
            }
            if replaced || currentID != appliedCurrentID,
               let currentID, let index = ids.firstIndex(of: currentID) {
                let y = CGFloat(index) * rowHeight
                if replaced { origin.y = y - (height - rowHeight) / 2 }
                else if y < origin.y { origin.y = y }
                else if y + rowHeight > origin.y + height { origin.y = y + rowHeight - height }
            }
            origin.x = min(max(0, origin.x), max(0, document.bounds.width - scroll.contentView.bounds.width))
            origin.y = min(max(0, origin.y), max(0, document.bounds.height - height))
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            previousY = scroll.contentView.bounds.minY
            appliedIDs = ids
            listingUpdatePending = false
            appliedCurrentID = currentID
        }

        private func didScroll() {
            guard !adjusting, !listingUpdatePending, let scroll, window != nil else { return }
            let viewport = scroll.contentView.bounds
            let delta = viewport.minY - previousY
            previousY = viewport.minY
            let margin = rowHeight * 8
            if delta < 0, viewport.minY <= margin {
                request(.before)
            } else if delta > 0, viewport.maxY >= CGFloat(ids.count) * rowHeight - margin {
                request(.after)
            }
        }

        private func request(_ direction: GenericDebugDisassemblyModel.Direction) {
            guard !pagingScheduled else { return }
            pagingScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pagingScheduled = false
                guard self.window != nil else { return }
                self.loadMore?(direction)
            }
        }
    }
}

/// Reads debuggee memory at an address or at the value of an expression, a page at a time.
/// Lines are labelled by their byte offset from the address that was asked for.
struct GenericDebugMemoryView: View {
    @ObservedObject var disassembly: GenericDebugDisassemblyModel
    @Binding var input: String
    @AppStorage("lithe.debug.memoryDisplay") private var storedDisplay = ""

    private var display: GenericDebugMemoryDisplay {
        get { GenericDebugMemoryDisplay(storedText: storedDisplay) }
        nonmutating set { storedDisplay = newValue.storedText }
    }

    var body: some View {
        VStack(spacing: 0) {
            inputRow
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inputRow: some View {
        HStack(spacing: 7) {
            LitheTextField("Address or expression", text: $input)
                .font(LitheTheme.uiFont(size: 12, design: .monospaced))
                .onSubmit { disassembly.readMemory(from: input) }
                .accessibilityLabel("Memory address or expression")
            if disassembly.isLoadingMemory {
                ProgressView().controlSize(.mini)
            }
            Button("Read") { disassembly.readMemory(from: input) }
                .buttonStyle(.litheNoPress)
                .font(LitheTheme.uiFont(size: 13))
                .foregroundStyle(LitheTheme.Debugger.value)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || !disassembly.canReadMemory)
            if disassembly.memory != nil {
                pageButton(.before, symbol: "chevron.up", label: "Previous page")
                pageButton(.after, symbol: "chevron.down", label: "Next page")
            }
            displayMenu
        }
        .padding(.horizontal, 10)
        .frame(height: LitheTheme.Debugger.inspectorHeaderHeight)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    /// Number base, value size, row width and byte order, in the manner of Visual Studio's
    /// memory window. The choice is kept across sessions and never changes the bytes read.
    private var displayMenu: some View {
        let current = display
        return LitheMenu {
            LitheContextMenuItem.submenu("Number Base") {
                for radix in GenericDebugMemoryDisplay.Radix.allCases {
                    LitheContextMenuItem.action(
                        Self.title(of: radix),
                        checked: current.radix == radix,
                        leadingCheckmark: true
                    ) { display = current.selecting(radix: radix) }
                }
            }
            LitheContextMenuItem.submenu("Value Size") {
                for size in GenericDebugMemoryDisplay.unitSizes {
                    LitheContextMenuItem.action(
                        Self.title(ofUnitSize: size),
                        checked: current.unitSize == size,
                        leadingCheckmark: true
                    ) { display = current.selecting(unitSize: size) }
                }
            }
            LitheContextMenuItem.submenu("Bytes per Row") {
                for size in GenericDebugMemoryDisplay.rowSizes {
                    LitheContextMenuItem.action(
                        String(size),
                        localizesTitle: false,
                        checked: current.bytesPerRow == size,
                        leadingCheckmark: true
                    ) {
                        var next = current
                        next.bytesPerRow = size
                        display = next.normalized()
                    }
                }
            }
            LitheContextMenuItem.submenu("Byte Order") {
                LitheContextMenuItem.action(
                    "Little Endian",
                    checked: current.byteOrder == .little,
                    leadingCheckmark: true
                ) {
                    var next = current
                    next.byteOrder = .little
                    display = next
                }
                LitheContextMenuItem.action(
                    "Big Endian",
                    checked: current.byteOrder == .big,
                    leadingCheckmark: true
                ) {
                    var next = current
                    next.byteOrder = .big
                    display = next
                }
            }
            LitheContextMenuItem.separator
            LitheContextMenuItem.action(
                "Show Text Column",
                checked: current.showsText,
                leadingCheckmark: true
            ) {
                var next = current
                next.showsText.toggle()
                display = next
            }
            LitheContextMenuItem.action("Reset Display Options", isEnabled: current != .standard) {
                display = .standard
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(LitheTheme.uiFont(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .litheToolbarIconButton()
        .help("Memory display options")
        .accessibilityLabel("Memory display options")
    }

    private static func title(of radix: GenericDebugMemoryDisplay.Radix) -> String {
        switch radix {
        case .hexadecimal: "Hexadecimal"
        case .unsignedDecimal: "Unsigned Decimal"
        case .signedDecimal: "Signed Decimal"
        case .octal: "Octal"
        case .binary: "Binary"
        case .floatingPoint: "Floating Point"
        }
    }

    private static func title(ofUnitSize size: Int) -> String {
        switch size {
        case 1: "1 byte"
        case 2: "2 bytes"
        case 4: "4 bytes"
        default: "8 bytes"
        }
    }

    private func pageButton(
        _ direction: GenericDebugDisassemblyModel.Direction,
        symbol: String,
        label: LocalizedStringKey
    ) -> some View {
        Button {
            disassembly.showMemoryPage(direction)
        } label: {
            Image(systemName: symbol)
                .font(LitheTheme.uiFont(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .litheToolbarIconButton()
        .help(label)
        .accessibilityLabel(label)
        .disabled(disassembly.isLoadingMemory)
    }

    @ViewBuilder
    private var content: some View {
        if let failure = disassembly.memoryFailure {
            failureText(failure)
        } else if let memory = disassembly.memory {
            dump(memory)
        } else {
            LitheToolWindowStatusText(
                disassembly.isLoadingMemory
                    ? "Reading memory…" : "Enter an address, or a register or variable that holds one"
            )
        }
    }

    private func failureText(_ failure: GenericDebugDisassemblyModel.MemoryFailure) -> some View {
        VStack {
            Spacer(minLength: 0)
            switch failure {
            case .unresolvedAddress:
                Text("The expression does not hold an address")
            case .adapter(let message):
                Text(verbatim: message)
            }
            Spacer(minLength: 0)
        }
        .font(LitheTheme.uiFont(size: 13))
        .foregroundStyle(LitheTheme.error)
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dump(_ memory: GenericDebugMemoryDump) -> some View {
        let layout = display
        let rows = layout.rows(of: memory.data)
        let changed = disassembly.memoryChangedIndices
        let target = Self.targetBytes(of: memory, in: rows)
        let labelWidth = CGFloat(
            rows.map { Self.offsetLabel(memory.pageOffset + $0.index).count }.max() ?? 0
        ) * Self.characterWidth
        let valuesWidth = CGFloat(layout.rowTextWidth) * Self.characterWidth
        return VStack(spacing: 0) {
            baseStrip(memory, changedCount: changed.count)
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            memoryRow(
                                row,
                                label: Self.offsetLabel(memory.pageOffset + row.index),
                                labelWidth: labelWidth,
                                valuesWidth: valuesWidth,
                                showsText: layout.showsText,
                                target: target,
                                changed: changed)
                        }
                        if memory.unreadableBytes > 0 {
                            Text("\(memory.unreadableBytes) bytes could not be read")
                                .font(LitheTheme.uiFont(size: 12))
                                .foregroundStyle(LitheTheme.warning)
                                .padding(.horizontal, 10)
                                .frame(height: Self.rowHeight, alignment: .leading)
                        }
                    }
                }
                .onAppear { reveal(in: proxy) }
                .onChange(of: disassembly.memoryRevealToken) { _ in reveal(in: proxy) }
                .onChange(of: storedDisplay) { _ in reveal(in: proxy) }
            }
        }
    }

    /// The reference the offsets count from, kept outside the scrolling rows so it can never
    /// cover the first one, and a count of the bytes that moved since the last stop.
    private func baseStrip(_ memory: GenericDebugMemoryDump, changedCount: Int) -> some View {
        HStack(spacing: 10) {
            Text("Offsets relative to \(memory.reference)")
                .foregroundStyle(LitheTheme.Tree.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if changedCount > 0 {
                Text("\(changedCount) bytes changed")
                    .foregroundStyle(LitheTheme.error)
                    .lineLimit(1)
            }
        }
        .font(LitheTheme.uiFont(size: 12, design: .monospaced))
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func memoryRow(
        _ row: GenericDebugMemoryDisplay.Row,
        label: String,
        labelWidth: CGFloat,
        valuesWidth: CGFloat,
        showsText: Bool,
        target: Range<Int>?,
        changed: Set<Int>
    ) -> some View {
        let rowBytes = row.index ..< row.index + row.text.count
        let holdsTarget = target.map { $0.overlaps(rowBytes) } ?? false
        return HStack(spacing: 14) {
            Text(verbatim: label)
                .foregroundStyle(holdsTarget ? LitheTheme.accent : LitheTheme.Tree.secondaryText)
                .frame(width: labelWidth, alignment: .leading)
            Text(valuesText(row, target: target, changed: changed))
                .foregroundStyle(LitheTheme.Tree.text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: valuesWidth, alignment: .leading)
            if showsText {
                Text(characterText(row, target: target, changed: changed))
                    .foregroundStyle(LitheTheme.Debugger.value)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .font(LitheTheme.uiFont(size: 12, design: .monospaced))
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight, alignment: .leading)
        .background(holdsTarget ? LitheTheme.accent.opacity(0.10) : Color.clear)
        .textSelection(.enabled)
    }

    /// The values of one row. The value that holds the searched address is highlighted, and
    /// a value with a byte that changed since the last stop is drawn in the error colour.
    private func valuesText(
        _ row: GenericDebugMemoryDisplay.Row,
        target: Range<Int>?,
        changed: Set<Int>
    ) -> AttributedString {
        var result = AttributedString()
        for (position, cell) in row.cells.enumerated() {
            if position > 0 { result.append(AttributedString(" ")) }
            var piece = AttributedString(cell.text)
            let bytes = cell.index ..< cell.index + cell.byteCount
            if let target, target.overlaps(bytes) {
                piece.backgroundColor = LitheTheme.accent.opacity(0.45)
            }
            if !changed.isEmpty, bytes.contains(where: changed.contains) {
                piece.foregroundColor = LitheTheme.error
            }
            result.append(piece)
        }
        return result
    }

    private func characterText(
        _ row: GenericDebugMemoryDisplay.Row,
        target: Range<Int>?,
        changed: Set<Int>
    ) -> AttributedString {
        var result = AttributedString()
        for (position, character) in row.text.enumerated() {
            var piece = AttributedString(String(character))
            let byte = row.index + position
            if let target, target.contains(byte) {
                piece.backgroundColor = LitheTheme.accent.opacity(0.45)
            }
            if changed.contains(byte) {
                piece.foregroundColor = LitheTheme.error
            }
            result.append(piece)
        }
        return result
    }

    /// The bytes of the value that holds the address that was asked for, if the page has it.
    static func targetBytes(
        of memory: GenericDebugMemoryDump,
        in rows: [GenericDebugMemoryDisplay.Row]
    ) -> Range<Int>? {
        guard let index = memory.targetIndex else { return nil }
        for row in rows {
            for cell in row.cells where cell.index <= index && index < cell.index + cell.byteCount {
                return cell.index ..< cell.index + cell.byteCount
            }
        }
        return nil
    }

    /// Brings the searched address to the middle of the view, or the top of the page when
    /// the page does not hold it (a neighbouring page, or a read that fell back to offset 0).
    private func reveal(in proxy: ScrollViewProxy) {
        guard let memory = disassembly.memory else { return }
        let rows = display.rows(of: memory.data)
        guard let first = rows.first else { return }
        if let target = Self.targetBytes(of: memory, in: rows),
           let row = rows.last(where: { $0.index <= target.lowerBound }) {
            proxy.scrollTo(row.index, anchor: .center)
        } else {
            proxy.scrollTo(first.index, anchor: .top)
        }
    }

    private static let rowHeight: CGFloat = 20

    private static var characterWidth: CGFloat {
        LitheTheme.editorFont(size: 12).maximumAdvancement.width
    }

    /// `+0x0010` relative to the address that was asked for; the host never adds to an address.
    static func offsetLabel(_ offset: Int) -> String {
        String(format: "%@0x%04llx", offset < 0 ? "-" : "+", UInt64(abs(offset)))
    }
}
