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
    /// The instruction pointer the list was last centred on.
    @State private var centeredAddress: String?

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
        NSFont(name: "JetBrainsMono-Regular", size: Self.fontSize)?.maximumAdvancement.width
            ?? Self.fontSize * 0.6
    }

    var body: some View {
        VStack(spacing: 0) {
            header
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
        return ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    loadMoreButton(.before)
                    ForEach(items) { item in
                        switch item {
                        case .symbol(_, let name):
                            symbolRow(name)
                        case .instruction(let instruction):
                            instructionRow(
                                instruction, addressColumn: addressColumn, bytesColumn: bytesColumn
                            )
                        }
                    }
                    loadMoreButton(.after)
                }
            }
            .onAppear { scrollToCurrent(proxy, centered: true) }
            // Stepping inside the listing moves the arrow, so the list only scrolls as far as
            // it takes to keep the arrow on screen instead of recentring on every step.
            .onChange(of: disassembly.currentAddress) { _ in scrollToCurrent(proxy, centered: false) }
            // A fresh listing is centred once; loading earlier or later instructions changes the
            // first row too but must leave the view where it is.
            .onChange(of: disassembly.rows.first?.address) { _ in
                if centeredAddress != disassembly.currentAddress { scrollToCurrent(proxy, centered: true) }
            }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, centered: Bool) {
        guard let current = disassembly.rows.first(where: { disassembly.isCurrent($0) }) else { return }
        centeredAddress = disassembly.currentAddress
        proxy.scrollTo(current.address, anchor: centered ? .center : nil)
    }

    private func loadMoreButton(_ direction: GenericDebugDisassemblyModel.Direction) -> some View {
        Button {
            disassembly.loadMore(direction)
        } label: {
            Text(direction == .before ? "Load earlier instructions" : "Load later instructions")
                .font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
                .padding(.horizontal, 10)
                .frame(height: Self.rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .disabled(disassembly.isLoading)
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
            TextField("Address or expression", text: $input)
                .textFieldStyle(.plain)
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

    /// The address the offsets count from, kept outside the scrolling rows so it can never
    /// cover the first one, and a count of the bytes that moved since the last stop.
    private func baseStrip(_ memory: GenericDebugMemoryDump, changedCount: Int) -> some View {
        HStack(spacing: 10) {
            Text("Offsets relative to \(memory.address)")
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
        NSFont(name: "JetBrainsMono-Regular", size: 12)?.maximumAdvancement.width ?? 7.2
    }

    /// `+0x0010` relative to the address that was asked for; the host never adds to an address.
    static func offsetLabel(_ offset: Int) -> String {
        String(format: "%@0x%04llx", offset < 0 ? "-" : "+", UInt64(abs(offset)))
    }
}
