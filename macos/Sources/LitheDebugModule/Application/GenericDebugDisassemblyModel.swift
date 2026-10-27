import Combine
import Foundation
import LitheCoreContracts

/// Text-level helpers for adapter-formatted addresses. The host never turns an address
/// into an integer or adds to it: it only decides whether two spellings name the same
/// address, so a 64-bit pointer can never be truncated or wrapped here.
public enum DebugAddressText {
    /// Lowercase, no `0x`, no leading zeros, so `0x0000000100003f50` equals `0x100003f50`.
    public static func canonical(_ address: String) -> String {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("0x") { text.removeFirst(2) }
        let digits = text.drop { $0 == "0" }
        return digits.isEmpty ? "0" : String(digits)
    }

    public static func areEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || canonical(lhs) == canonical(rhs)
    }

    /// The first `0x…` literal in `text`, such as the pointer in a register value
    /// `0x000000016fdff8a0 -> ...`.
    public static func firstHexLiteral(in text: String) -> String? {
        guard let range = text.range(of: "0[xX][0-9a-fA-F]+", options: .regularExpression) else {
            return nil
        }
        return String(text[range])
    }

    /// True when the whole trimmed text is one `0x…` literal.
    public static func isHexLiteral(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: "^0[xX][0-9a-fA-F]+$", options: .regularExpression) != nil
    }
}

/// An instruction breakpoint set from the disassembly view. It lives only as long as the
/// session it was set in: the same code sits at another address in the next run.
public struct GenericDebugInstructionBreakpoint: Identifiable, Equatable, Sendable {
    public let address: String
    public var enabled: Bool
    public var verified: Bool
    public var message: String?

    public var id: String { DebugAddressText.canonical(address) }

    public init(address: String, enabled: Bool = true, verified: Bool = false, message: String? = nil) {
        self.address = address
        self.enabled = enabled
        self.verified = verified
        self.message = message
    }
}

/// One page of debuggee bytes. Lines are labelled with their byte offset from `reference`
/// so the host does not do address arithmetic.
public struct GenericDebugMemoryDump: Equatable, Sendable {
    public static let pageSize = 256
    /// Bytes read before the address that was asked for, so the address is not the first thing
    /// on the page: the user sees what precedes it and the highlighted bytes are not at the edge.
    public static let contextBytes = 64

    /// What the user asked for; later pages are requested relative to it.
    public let reference: String
    /// Bytes from `reference` to the first byte of this page.
    public let pageOffset: Int
    /// Where the adapter says the first byte is.
    public let address: String
    /// Bytes after the readable ones that the adapter could not read.
    public let unreadableBytes: Int
    public let data: Data

    public init(reference: String, pageOffset: Int, address: String, unreadableBytes: Int, data: Data) {
        self.reference = reference
        self.pageOffset = pageOffset
        self.address = address
        self.unreadableBytes = unreadableBytes
        self.data = data
    }

    /// Index in `data` of the byte at `reference`, when this page holds it.
    public var targetIndex: Int? {
        let index = -pageOffset
        return index >= 0 && index < data.count ? index : nil
    }
}

/// State behind the disassembly and memory views: which instructions are listed around
/// the selected frame's instruction pointer, the instruction breakpoints the user set, and
/// the memory page being read. It holds no UI text; the view localizes every message.
@MainActor
public final class GenericDebugDisassemblyModel: ObservableObject {
    /// What the model needs from the feature model that owns it.
    public struct Environment {
        public var session: () -> (any DebugAdapterControllingSession)?
        public var capabilities: () -> DebugAdapterCapabilities
        public var selectedFrameID: () -> Int?
        public var breakpointsChanged: (DebugSessionID, [DebugInstructionBreakpoint]) -> Void

        public init(
            session: @escaping () -> (any DebugAdapterControllingSession)?,
            capabilities: @escaping () -> DebugAdapterCapabilities,
            selectedFrameID: @escaping () -> Int?,
            breakpointsChanged: @escaping (DebugSessionID, [DebugInstructionBreakpoint]) -> Void
        ) {
            self.session = session
            self.capabilities = capabilities
            self.selectedFrameID = selectedFrameID
            self.breakpointsChanged = breakpointsChanged
        }
    }

    public enum Direction { case before, after }

    public enum MemoryFailure: Equatable {
        /// The typed text was neither a `0x…` address nor an expression that evaluates to one.
        case unresolvedAddress
        /// The adapter's own diagnostic, shown as it came.
        case adapter(String)
    }

    /// Instructions requested ahead of and around the instruction pointer.
    static let instructionsBefore = 24
    static let initialInstructionCount = 96
    static let pageInstructionCount = 64
    /// Instructions left below the current one before the listing is extended while stepping.
    static let edgeInstructionCount = 8

    @Published public private(set) var isPresented = false
    @Published public private(set) var rows: [DebugDisassembledInstruction] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var loadFailure: String?
    @Published public private(set) var breakpoints: [GenericDebugInstructionBreakpoint] = []
    @Published public private(set) var memory: GenericDebugMemoryDump?
    @Published public private(set) var isLoadingMemory = false
    @Published public private(set) var memoryFailure: MemoryFailure?
    /// Indexes in `memory.data` whose byte differs from the same page read before the last step.
    @Published public private(set) var memoryChangedIndices: Set<Int> = []
    /// Bumped when the user asked for a page, so the view brings the highlighted bytes into view.
    /// A refresh after a step leaves it alone: it must not move what the user is reading.
    @Published public private(set) var memoryRevealToken = 0

    /// Address of the selected frame's current instruction, as the adapter reported it.
    @Published public private(set) var currentAddress: String?

    public var environment: Environment?

    private var disassemblyGeneration = 0
    private var memoryGeneration = 0
    private var presentedAutomatically = false
    private var activeSessionID: DebugSessionID?
    private var breakpointsBySession: [DebugSessionID: [GenericDebugInstructionBreakpoint]] = [:]

    public init() {}

    // MARK: - Capabilities

    public var canDisassemble: Bool { environment?.capabilities().supportsDisassembleRequest ?? false }
    public var canReadMemory: Bool { environment?.capabilities().supportsReadMemoryRequest ?? false }
    public var canSetInstructionBreakpoints: Bool {
        environment?.capabilities().supportsInstructionBreakpoints ?? false
    }

    /// Stepping moves one instruction while the disassembly is on screen, as long as the
    /// adapter can step by instruction. Otherwise a step would skip a whole source line.
    public var stepsByInstruction: Bool {
        isPresented && canStepByInstruction
    }

    /// Whether the adapter honours `granularity: instruction` on step requests.
    public var canStepByInstruction: Bool {
        environment?.capabilities().supportsSteppingGranularity ?? false
    }

    // MARK: - Presentation

    public func present() {
        guard !isPresented else { return }
        isPresented = true
        presentedAutomatically = false
        reload()
    }

    public func dismiss() {
        guard isPresented else { return }
        isPresented = false
        presentedAutomatically = false
        disassemblyGeneration &+= 1
        isLoading = false
    }

    public func toggle() {
        isPresented ? dismiss() : present()
    }

    public func isCurrent(_ instruction: DebugDisassembledInstruction) -> Bool {
        guard let currentAddress else { return false }
        return DebugAddressText.areEqual(instruction.address, currentAddress)
    }

    // MARK: - Following the stack

    /// The selected frame changed. A frame without source has nothing else to show, so
    /// the view opens by itself and closes again once a frame with source is selected.
    ///
    /// `preservingView` is a step landing in the same thread. The listing then stays put and only
    /// the current-instruction marker moves, unless the new instruction is outside the listed
    /// range. The memory page stays on screen and is read again quietly, so bytes the step
    /// changed are marked instead of the whole page blinking away.
    public func frameSelected(_ frame: DebugStackFrame, preservingView: Bool = false) {
        disassemblyGeneration &+= 1
        memoryGeneration &+= 1
        isLoading = false
        currentAddress = frame.instructionPointerReference
        if preservingView {
            refreshMemoryInPlace()
        } else {
            clearMemory()
        }
        if frame.isSourceless, currentAddress != nil, canDisassemble {
            if !isPresented {
                isPresented = true
                presentedAutomatically = true
            }
        } else if presentedAutomatically {
            isPresented = false
            presentedAutomatically = false
        }
        if preservingView, isPresented, currentAddress != nil, followInstructionPointer() {
            return
        }
        reload()
    }

    /// Keeps the existing listing when it already holds the current instruction. Returns false
    /// when the listing has to be read again.
    private func followInstructionPointer() -> Bool {
        guard let index = rows.firstIndex(where: { isCurrent($0) }) else { return false }
        // Stepping towards the end of the listing: extend it before the marker runs off.
        if rows.count - index <= Self.edgeInstructionCount { loadMore(.after) }
        return true
    }

    /// The debuggee resumed or the stack was thrown away, so every address is stale.
    public func invalidate() {
        suspendRequests()
        currentAddress = nil
        rows = []
        isLoading = false
        loadFailure = nil
        memory = nil
        memoryChangedIndices = []
        memoryFailure = nil
        isLoadingMemory = false
    }

    /// Retires callbacks before the session cancels operations synchronously. A step keeps
    /// the displayed bytes and instructions, but no response may mutate the previous stop.
    public func suspendRequests() {
        disassemblyGeneration &+= 1
        memoryGeneration &+= 1
        isLoading = false
        isLoadingMemory = false
    }

    // MARK: - Sessions

    /// The visible session changed; breakpoints belong to one session's debuggee.
    public func activate(sessionID: DebugSessionID?) {
        guard activeSessionID != sessionID else { return }
        activeSessionID = sessionID
        breakpoints = sessionID.flatMap { breakpointsBySession[$0] } ?? []
        invalidate()
    }

    public func forget(sessionID: DebugSessionID) {
        breakpointsBySession[sessionID] = nil
        if activeSessionID == sessionID {
            breakpoints = []
        }
    }

    // MARK: - Disassembly

    public func reload() {
        guard isPresented,
              let anchor = currentAddress,
              canDisassemble,
              let session = environment?.session() else {
            rows = []
            isLoading = false
            return
        }
        disassemblyGeneration &+= 1
        let token = disassemblyGeneration
        isLoading = true
        loadFailure = nil
        request(
            session: session,
            generation: token,
            reference: anchor,
            offset: -Self.instructionsBefore,
            count: Self.initialInstructionCount,
            retriesForward: true
        ) { [weak self] instructions in
            guard let self, self.disassemblyGeneration == token else { return }
            self.rows = instructions
            self.isLoading = false
        } onFailure: { [weak self] message in
            guard let self, self.disassemblyGeneration == token else { return }
            self.rows = []
            self.loadFailure = message
            self.isLoading = false
        }
    }

    /// Lists another page above the first or below the last instruction.
    public func loadMore(_ direction: Direction) {
        guard !isLoading,
              let session = environment?.session(),
              let edge = direction == .before ? rows.first : rows.last else { return }
        disassemblyGeneration &+= 1
        let token = disassemblyGeneration
        isLoading = true
        loadFailure = nil
        request(
            session: session,
            generation: token,
            reference: edge.address,
            offset: direction == .before ? -Self.pageInstructionCount : 1,
            count: Self.pageInstructionCount,
            retriesForward: false
        ) { [weak self] instructions in
            guard let self, self.disassemblyGeneration == token else { return }
            let known = Set(self.rows.map { DebugAddressText.canonical($0.address) })
            let fresh = instructions.filter { !known.contains(DebugAddressText.canonical($0.address)) }
            self.rows = direction == .before ? fresh + self.rows : self.rows + fresh
            self.isLoading = false
        } onFailure: { [weak self] message in
            guard let self, self.disassemblyGeneration == token else { return }
            self.loadFailure = message
            self.isLoading = false
        }
    }

    /// An adapter may refuse a negative `instructionOffset`; the first window then starts
    /// at the instruction pointer instead of failing the whole view.
    private func request(
        session: any DebugAdapterControllingSession,
        generation: Int,
        reference: String,
        offset: Int,
        count: Int,
        retriesForward: Bool,
        onSuccess: @escaping ([DebugDisassembledInstruction]) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        session.requestDisassembly(
            memoryReference: reference,
            instructionOffset: offset,
            instructionCount: count
        ) { [weak self] result in
            guard let self, self.disassemblyGeneration == generation else { return }
            switch result {
            case .success(let instructions):
                onSuccess(instructions)
            case .failure(let error):
                if retriesForward, offset < 0 {
                    self.request(
                        session: session,
                        generation: generation,
                        reference: reference,
                        offset: 0,
                        count: count,
                        retriesForward: false,
                        onSuccess: onSuccess,
                        onFailure: onFailure
                    )
                } else {
                    onFailure(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Instruction breakpoints

    public func breakpoint(at address: String) -> GenericDebugInstructionBreakpoint? {
        breakpoints.first { DebugAddressText.areEqual($0.address, address) }
    }

    /// Sets or clears the breakpoint at an instruction address from the disassembly.
    public func toggleBreakpoint(at address: String) {
        guard canSetInstructionBreakpoints, activeSessionID != nil else { return }
        if let index = breakpoints.firstIndex(where: { DebugAddressText.areEqual($0.address, address) }) {
            breakpoints.remove(at: index)
        } else {
            breakpoints.append(GenericDebugInstructionBreakpoint(address: address))
        }
        publishBreakpoints()
    }

    public func removeBreakpoint(_ breakpoint: GenericDebugInstructionBreakpoint) {
        breakpoints.removeAll { $0.id == breakpoint.id }
        publishBreakpoints()
    }

    /// The adapter reported whether an instruction breakpoint took effect.
    public func resolveBreakpoint(reference: String, verified: Bool, message: String?) {
        guard let index = breakpoints.firstIndex(where: { DebugAddressText.areEqual($0.address, reference) }) else {
            return
        }
        breakpoints[index].verified = verified
        breakpoints[index].message = message
        if let activeSessionID {
            breakpointsBySession[activeSessionID] = breakpoints
        }
    }

    private func publishBreakpoints() {
        guard let activeSessionID else { return }
        breakpointsBySession[activeSessionID] = breakpoints
        environment?.breakpointsChanged(
            activeSessionID,
            breakpoints.map {
                DebugInstructionBreakpoint(instructionReference: $0.address, enabled: $0.enabled)
            }
        )
    }

    // MARK: - Memory

    /// Reads memory at a `0x…` address, or at what an expression such as a register name
    /// evaluates to in the selected frame.
    public func readMemory(from input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if DebugAddressText.isHexLiteral(text) {
            readMemory(around: text)
            return
        }
        guard let session = environment?.session() else { return }
        memoryGeneration &+= 1
        let token = memoryGeneration
        isLoadingMemory = true
        memoryFailure = nil
        session.evaluate(text, frameID: environment?.selectedFrameID()) { [weak self] result in
            guard let self, self.memoryGeneration == token else { return }
            switch result {
            case .success(let variable):
                if let address = DebugAddressText.firstHexLiteral(in: variable.value) {
                    self.readMemory(around: address)
                } else {
                    self.isLoadingMemory = false
                    self.memoryFailure = .unresolvedAddress
                }
            case .failure(let error):
                self.isLoadingMemory = false
                self.memoryFailure = .adapter(error.localizedDescription)
            }
        }
    }

    /// Reads a page that starts a little before `reference`, so what precedes the address is
    /// visible and the address itself is not on the first row. An adapter that cannot read
    /// below the address (the start of a mapping, or no negative offsets) gets the page that
    /// starts at the address instead.
    private func readMemory(around reference: String) {
        loadMemory(
            reference: reference,
            pageOffset: -GenericDebugMemoryDump.contextBytes,
            fallbackPageOffset: 0
        )
    }

    /// Reads the page that starts `pageOffset` bytes from `reference`.
    public func readMemory(reference: String, pageOffset: Int) {
        loadMemory(reference: reference, pageOffset: pageOffset, fallbackPageOffset: nil)
    }

    private func loadMemory(reference: String, pageOffset: Int, fallbackPageOffset: Int?) {
        guard canReadMemory, let session = environment?.session() else { return }
        memoryGeneration &+= 1
        let token = memoryGeneration
        isLoadingMemory = true
        memoryFailure = nil
        session.requestReadMemory(
            memoryReference: reference,
            offset: pageOffset,
            count: GenericDebugMemoryDump.pageSize
        ) { [weak self] result in
            guard let self, self.memoryGeneration == token else { return }
            var failure: String?
            switch result {
            case .success(let read) where read.data.isEmpty && fallbackPageOffset != nil:
                failure = ""
            case .success(let read):
                self.isLoadingMemory = false
                self.memoryChangedIndices = []
                self.memory = GenericDebugMemoryDump(
                    reference: reference,
                    pageOffset: pageOffset,
                    address: read.address,
                    unreadableBytes: read.unreadableBytes,
                    data: read.data
                )
                self.memoryRevealToken &+= 1
            case .failure(let error):
                failure = error.localizedDescription
            }
            guard let failure else { return }
            if let fallbackPageOffset {
                self.loadMemory(reference: reference, pageOffset: fallbackPageOffset, fallbackPageOffset: nil)
            } else {
                self.isLoadingMemory = false
                self.memoryFailure = .adapter(failure)
            }
        }
    }

    public func showMemoryPage(_ direction: Direction) {
        guard let memory else { return }
        let step = GenericDebugMemoryDump.pageSize
        let next = memory.pageOffset + (direction == .after ? step : -step)
        readMemory(reference: memory.reference, pageOffset: next)
    }

    /// Reads the page on screen again after a step, with no spinner and no scrolling. The bytes
    /// the step changed are recorded so the view can mark them.
    private func refreshMemoryInPlace() {
        guard let current = memory, canReadMemory, let session = environment?.session() else {
            clearMemory()
            return
        }
        memoryFailure = nil
        isLoadingMemory = false
        let token = memoryGeneration
        session.requestReadMemory(
            memoryReference: current.reference,
            offset: current.pageOffset,
            count: GenericDebugMemoryDump.pageSize
        ) { [weak self] result in
            guard let self, self.memoryGeneration == token else { return }
            switch result {
            case .success(let read):
                let fresh = GenericDebugMemoryDump(
                    reference: current.reference,
                    pageOffset: current.pageOffset,
                    address: read.address,
                    unreadableBytes: read.unreadableBytes,
                    data: read.data
                )
                let changed = Self.changedIndices(from: current.data, to: fresh.data)
                if self.memoryChangedIndices != changed { self.memoryChangedIndices = changed }
                if self.memory != fresh { self.memory = fresh }
            case .failure(let error):
                // Showing the old bytes as if they were current would mislead more than an error.
                self.memory = nil
                self.memoryChangedIndices = []
                self.memoryFailure = .adapter(error.localizedDescription)
            }
        }
    }

    static func changedIndices(from old: Data, to new: Data) -> Set<Int> {
        var changed: Set<Int> = []
        for index in 0 ..< min(old.count, new.count)
        where old[old.startIndex + index] != new[new.startIndex + index] {
            changed.insert(index)
        }
        return changed
    }

    public func clearMemory() {
        memoryGeneration &+= 1
        memory = nil
        memoryChangedIndices = []
        memoryFailure = nil
        isLoadingMemory = false
    }
}
