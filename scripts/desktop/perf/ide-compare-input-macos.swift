// Presses keys in an editor and times what the editor shows in response, for
// ide-compare-latency.mjs. It reads one JSON command per line on stdin and answers each with one
// JSON line on stdout:
//
//   {"op":"permissions"}                    what this process may do (Accessibility, posting
//                                           events, recording the screen)
//   {"op":"input-source","id":ID}           selects the keyboard input source ID and answers with
//                                           the one selected before
//   {"op":"calm","pid":PID,"stableMs":S,"timeoutMs":T}
//                                           waits until Mission Control and App Exposé are closed and
//                                           the largest window of PID has kept its frame for S ms
//   {"op":"attach","pid":PID}               once calm, starts recording the largest window of PID,
//                                           with every other window of that application (popups,
//                                           dialogs) that lands on it
//   {"op":"keys","pid":PID,"keys":[KEY...]} presses the keys in order
//   {"op":"quiet","minPixels":N,"quietMs":Q,"timeoutMs":T}
//                                           waits until the window has not changed for Q ms
//   {"op":"measure","pid":PID,"keys":[KEY...],"minPixels":N,"quietMs":Q,"timeoutMs":T}
//                                           presses the keys and times the window's response: the
//                                           first frame that differs from the one before the last
//                                           key, and the last frame that changed before the window
//                                           stayed the same for Q ms
//   {"op":"measure","pid":PID,"point":{"x":X,"y":Y},"via":{"x":VX,"y":VY},"viaMs":V,...}
//                                           the same, for the mouse pointer coming to rest at X,Y
//                                           (screen points) instead of a key; with via, the pointer
//                                           first rests V ms (default 150) at VX,VY, as a mouse comes
//                                           over other text, and the time starts when it moves on
//   {"op":"point","pid":PID,"x":X,"y":Y}    moves the mouse pointer to X,Y
//   {"op":"locate","pid":PID,"keys":[KEY...],"skipBottom":B,"quietMs":Q,"timeoutMs":T}
//                                           presses the keys, which should move the caret one
//                                           character right, and answers with the screen point in the
//                                           middle of that character, found by comparing the window
//                                           before and after; the lowest B points, the status bar
//                                           that shows the caret's column, are left out
//   {"op":"snapshot","file":PATH}           writes the last frame as a PNG
//   {"op":"frontmost"}                      the process of the frontmost window
//   {"op":"activate","pid":PID}             brings PID and its largest window to the front through
//                                           Accessibility, and waits up to 3 s until it is there
//
// A KEY is {"key":NAME,"mods":["cmd","shift","alt","ctrl"]} or {"text":"..."}: NAME is a letter,
// digit or punctuation of the ANSI layout or return, escape, tab, space, backspace, delete, left,
// right, up, down, home, end, f1 to f12, and text is typed character by character on that layout
// (the ABC input source has to be selected for text to arrive as typed). Keys go to the system
// event stream, like a keyboard's, and only while PID owns the frontmost window: a key is never
// pressed, and the pointer never moved, in another application, and the command fails instead.
//
// Mission Control and App Exposé draw every window shrunk, so a recording cut to the window's frame
// would see something else. While either is open, or the recorded window has moved, keys are not
// pressed and a measurement that sees it stops; both fail with an error starting "disturbed:".
//
// A frame counts as changed when at least minPixels of its sampled pixels (every second pixel of
// every second row, at one pixel per point) differ. Frame times are the display times
// ScreenCaptureKit reports, on the same clock as the moment a key is posted, so the measured time
// runs from the key press to the frame on the display. The window is recorded without the mouse
// pointer, and the text caret has to be told not to blink.
//
// Build: xcrun swiftc -O -swift-version 5 -o ide-compare-input ide-compare-input-macos.swift
import AppKit
import Carbon.HIToolbox
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)

func milliseconds(_ ticks: UInt64) -> Double {
    Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e6
}

func ticks(milliseconds ms: Double) -> UInt64 {
    UInt64(ms * 1e6 * Double(timebase.denom) / Double(timebase.numer))
}

struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// Frame is one recorded frame: when it was shown and how many sampled pixels differ from the frame
// before it and from the baseline (the frame before a measured key; 0 when there is none).
struct Frame {
    let ticks: UInt64
    let changedFromPrevious: Int
    let changedFromBaseline: Int
}

// Samples is one frame's sampled pixels: every step-th pixel of every step-th row.
struct Samples {
    let values: [UInt32]
    let columns: Int
    let rows: Int
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let lock = NSLock()
    private var previous: [UInt32] = []
    private var scratch: [UInt32] = []
    private var baseline: [UInt32]?
    private var frames: [Frame] = []
    private var latest: CVPixelBuffer?
    private var columns = 0
    private var rows = 0
    private var failure: String?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "ide-compare.frames")
    let step = 2
    // The frame of the recorded window in screen points when recording started; keys are only
    // pressed, and measurements only count, while the window is still there.
    private(set) var attachedFrame: CGRect?

    func start(pid: pid_t) async throws -> [String: Any] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width >= 400 && $0.frame.height >= 300
        }
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let application = window.owningApplication
        else { throw DriverError("no window of process \(pid) on screen") }
        attachedFrame = window.frame
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else {
            throw DriverError("no display")
        }
        // Every window of the application on the display, cut to the main window: popups and
        // dialogs the editor opens as windows of their own are seen where they cover it.
        let filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
        let config = SCStreamConfiguration()
        let rect = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.sourceRect = rect
        config.width = Int(rect.width)
        config.height = Int(rect.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        config.showsCursor = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        return [
            "windowID": Int(window.windowID), "title": window.title ?? "",
            "x": rect.minX, "y": rect.minY, "w": rect.width, "h": rect.height,
        ]
    }

    func stop() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        attachedFrame = nil
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        failure = "\(error)"
        lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = sampleBuffer.imageBuffer
        else { return }
        let shown = (info[.displayTime] as? UInt64) ?? mach_absolute_time()
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let count = ((width + step - 1) / step) * ((height + step - 1) / step)
        let columns = (width + step - 1) / step
        let rows = (height + step - 1) / step

        lock.lock()
        defer { lock.unlock() }
        var out = scratch.count == count ? scratch : [UInt32](repeating: 0, count: count)
        scratch = []
        let before = previous.count == count ? previous : [UInt32](repeating: 0xFFFF_FFFF, count: count)
        let against = baseline?.count == count ? baseline! : before
        let step = self.step
        var fromPrevious = 0
        var fromBaseline = 0
        out.withUnsafeMutableBufferPointer { out in
            before.withUnsafeBufferPointer { before in
                against.withUnsafeBufferPointer { against in
                    var index = 0
                    for y in stride(from: 0, to: height, by: step) {
                        let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt32.self)
                        for x in stride(from: 0, to: width, by: step) {
                            let value = row[x] & 0x00FF_FFFF
                            out[index] = value
                            if before[index] != value { fromPrevious += 1 }
                            if against[index] != value { fromBaseline += 1 }
                            index += 1
                        }
                    }
                }
            }
        }
        if baseline?.count != count { fromBaseline = 0 }
        scratch = previous
        previous = out
        latest = pixels
        self.columns = columns
        self.rows = rows
        frames.append(Frame(ticks: shown, changedFromPrevious: fromPrevious, changedFromBaseline: fromBaseline))
        if frames.count > 20000 { frames.removeFirst(10000) }
    }

    // mark returns the frame count to read later frames from, and with baseline makes the current
    // frame the one later frames are compared with.
    func mark(baseline setBaseline: Bool) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw DriverError("recording stopped: \(failure)") }
        if stream == nil { throw DriverError("not attached") }
        if setBaseline { baseline = previous }
        return frames.count
    }

    func frames(since index: Int) -> [Frame] {
        lock.lock()
        defer { lock.unlock() }
        let start = min(index, frames.count)
        return Array(frames[start...])
    }

    // samples returns the sampled pixels of the last frame, row by row.
    func samples() -> Samples? {
        lock.lock()
        defer { lock.unlock() }
        guard columns > 0, previous.count == columns * rows else { return nil }
        return Samples(values: previous, columns: columns, rows: rows)
    }

    func clearBaseline() {
        lock.lock()
        baseline = nil
        lock.unlock()
    }

    func snapshot(to path: String) throws {
        lock.lock()
        let pixels = latest
        lock.unlock()
        guard let pixels else { throw DriverError("no frame yet") }
        let image = CIImage(cvPixelBuffer: pixels)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw DriverError("cannot write \(path)") }
        CGImageDestinationAddImage(destination, cgImage, nil)
        if !CGImageDestinationFinalize(destination) { throw DriverError("cannot write \(path)") }
    }
}

// MARK: Keys

let namedKeys: [String: CGKeyCode] = [
    "return": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53, "delete": 117,
    "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    "f9": 101, "f10": 109, "f11": 103, "f12": 111,
]

// Keys a keyboard reports with the Fn flag set, whatever modifiers are held.
let functionKeys: Set<CGKeyCode> = [117, 123, 124, 125, 126, 115, 119, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

// The ANSI layout: each character's key and whether Shift types it.
let layout: [Character: (CGKeyCode, Bool)] = {
    var table: [Character: (CGKeyCode, Bool)] = [:]
    let plain: [(String, CGKeyCode)] = [
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
        ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19),
        ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28),
        ("0", 29), ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37), ("j", 38),
        ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44), ("n", 45), ("m", 46), (".", 47),
        ("`", 50), (" ", 49),
    ]
    for (character, code) in plain {
        table[Character(character)] = (code, false)
        if character.first!.isLetter { table[Character(character.uppercased())] = (code, true) }
    }
    let shifted: [(String, CGKeyCode)] = [
        ("!", 18), ("@", 19), ("#", 20), ("$", 21), ("^", 22), ("%", 23), ("+", 24), ("(", 25), ("&", 26),
        ("_", 27), ("*", 28), (")", 29), ("}", 30), ("{", 33), ("\"", 39), (":", 41), ("|", 42), ("<", 43),
        ("?", 44), (">", 47), ("~", 50),
    ]
    for (character, code) in shifted { table[Character(character)] = (code, true) }
    return table
}()

struct Press {
    let code: CGKeyCode
    let flags: CGEventFlags
}

func presses(_ specs: [[String: Any]]) throws -> [Press] {
    var result: [Press] = []
    for spec in specs {
        if let text = spec["text"] as? String {
            for character in text {
                guard let (code, shift) = layout[character] else { throw DriverError("cannot type \(character)") }
                result.append(Press(code: code, flags: shift ? .maskShift : []))
            }
            continue
        }
        guard let name = spec["key"] as? String else { throw DriverError("a key needs key or text") }
        var flags: CGEventFlags = []
        for modifier in spec["mods"] as? [String] ?? [] {
            switch modifier {
            case "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt": flags.insert(.maskAlternate)
            case "ctrl": flags.insert(.maskControl)
            default: throw DriverError("unknown modifier \(modifier)")
            }
        }
        let code: CGKeyCode
        if let named = namedKeys[name] {
            code = named
        } else if name.count == 1, let (typed, _) = layout[Character(name)] {
            code = typed
        } else {
            throw DriverError("unknown key \(name)")
        }
        if functionKeys.contains(code) { flags.insert(.maskSecondaryFn) }
        result.append(Press(code: code, flags: flags))
    }
    return result
}

func frontmostPid() -> pid_t? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    for window in list where (window[kCGWindowLayer as String] as? Int) == 0 {
        if let pid = window[kCGWindowOwnerPID as String] as? Int { return pid_t(pid) }
    }
    return nil
}

// Windows the system shows over every application while Mission Control or App Exposé is open;
// the windows of every application are drawn shrunk under them.
let overlayWindowNames: Set<String> = ["ExposeShieldWindow", "Spaces Bar"]

// ScreenState is what the screen shows of the editor: whether Mission Control or App Exposé is
// open, and the frame of the editor's largest window (nil when none is on screen).
struct ScreenState {
    let overlay: String?
    let frame: CGRect?
}

func screenState(pid: pid_t) -> ScreenState {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    var overlay: String?
    var frame: CGRect?
    for window in list {
        let owner = window[kCGWindowOwnerName as String] as? String ?? ""
        let name = window[kCGWindowName as String] as? String ?? ""
        if (owner == "WindowManager" || owner == "Dock"), overlayWindowNames.contains(name) { overlay = name }
        guard (window[kCGWindowOwnerPID as String] as? Int) == Int(pid), (window[kCGWindowLayer as String] as? Int) == 0,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds)
        else { continue }
        if frame == nil || rect.width * rect.height > frame!.width * frame!.height { frame = rect }
    }
    return ScreenState(overlay: overlay, frame: frame)
}

// disturbance says why the screen does not show the editor's window as it was attached, or nil.
func disturbance(pid: pid_t, attached: CGRect?) -> String? {
    let state = screenState(pid: pid)
    if let overlay = state.overlay { return "\(overlay) is on screen (Mission Control or App Exposé)" }
    guard let frame = state.frame else { return "no window of process \(pid) on screen" }
    if let attached, !sameFrame(frame, attached) { return "the window moved from \(attached) to \(frame)" }
    return nil
}

func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
}

// waitCalm returns once neither Mission Control nor App Exposé is open and the editor's largest
// window has kept the same frame for stableMs, or throws after timeoutMs.
func waitCalm(pid: pid_t, stableMs: Double, timeoutMs: Double) async throws -> CGRect {
    let start = mach_absolute_time()
    var frame: CGRect?
    var since = start
    var last = ""
    while true {
        let state = screenState(pid: pid)
        let now = mach_absolute_time()
        if let overlay = state.overlay {
            last = "\(overlay) is on screen"
            frame = nil
        } else if let current = state.frame {
            if frame == nil || !sameFrame(current, frame!) {
                frame = current
                since = now
            } else if milliseconds(now - since) >= stableMs {
                return current
            }
            last = "the window is at \(current)"
        } else {
            last = "no window of process \(pid) on screen"
            frame = nil
        }
        if milliseconds(now - start) >= timeoutMs { throw DriverError("disturbed: not calm after \(Int(timeoutMs)) ms: \(last)") }
        await sleep(ms: 100)
    }
}

// activate brings the application of PID and its largest window to the front through
// Accessibility, as a click on the window would. Launch Services is not used, because with
// several running copies of one application it picks the copy itself.
func activate(pid: pid_t) async throws {
    let application = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    let start = mach_absolute_time()
    while frontmostPid() != pid || NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
        if milliseconds(mach_absolute_time() - start) >= 3000 { throw DriverError("process \(pid) does not come to the front") }
        await sleep(ms: 50)
    }
    // An application brought to the front this way keeps whichever window was key, or none: keys
    // with a menu shortcut still work, every other key is lost. Its largest window is made key,
    // now that the application is active, and a click on the middle of its title bar, where no
    // editor has a control, does it if accessibility could not.
    guard let window = largestWindow(application) else { throw DriverError("process \(pid) has no window") }
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    if await isKey(window, of: application) { return }
    var origin = CGPoint.zero
    var size = CGSize.zero
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success, let value { AXValueGetValue(value as! AXValue, .cgPoint, &origin) }
    if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success, let value { AXValueGetValue(value as! AXValue, .cgSize, &size) }
    try click(at: CGPoint(x: origin.x + size.width / 2, y: origin.y + 14), pid: pid)
    if await isKey(window, of: application) { return }
    throw DriverError("the window of process \(pid) does not take the keyboard")
}

// largestWindow returns the application's largest window: the editor's, not a panel's.
func largestWindow(_ application: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success, let windows = value as? [AXUIElement] else { return nil }
    var largest: (window: AXUIElement, area: CGFloat)?
    for window in windows {
        var sizeValue: CFTypeRef?
        var size = CGSize.zero
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success, let sizeValue {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }
        if largest == nil || size.width * size.height > largest!.area { largest = (window, size.width * size.height) }
    }
    return largest?.window
}

// isKey waits up to a second for the window to become the application's focused window, the one
// that gets the keys.
func isKey(_ window: AXUIElement, of application: AXUIElement) async -> Bool {
    let start = mach_absolute_time()
    while milliseconds(mach_absolute_time() - start) < 1000 {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success, let value,
           CFEqual(value, window) { return true }
        await sleep(ms: 50)
    }
    return false
}

// click presses and releases the left mouse button at a point in screen points.
func click(at point: CGPoint, pid: pid_t) throws {
    // The window may not be attached yet, so only the application and the overlays are checked.
    guard frontmostPid() == pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        throw DriverError("process \(pid) is not frontmost; nothing was clicked")
    }
    if let overlay = screenState(pid: pid).overlay { throw DriverError("disturbed: \(overlay) is on screen; nothing was clicked") }
    let source = CGEventSource(stateID: .hidSystemState)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
            throw DriverError("cannot create a mouse event")
        }
        event.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}

// ensureInFront throws unless PID owns the frontmost window and the screen shows it as attached.
func ensureInFront(pid: pid_t) throws {
    guard frontmostPid() == pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        throw DriverError("process \(pid) is not frontmost; no key was pressed")
    }
    if let reason = disturbance(pid: pid, attached: recorder.attachedFrame) {
        throw DriverError("disturbed: \(reason); no key was pressed")
    }
}

// movePointer moves the mouse pointer to a point in screen points, like a mouse does.
func movePointer(to point: CGPoint, pid: pid_t) throws {
    try ensureInFront(pid: pid)
    guard let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
        throw DriverError("cannot create a mouse event")
    }
    event.post(tap: .cghidEventTap)
}

// caretSpot compares the frames before and after the caret moved one character right, and
// returns that character, in sampled pixels. Only the caret changed on its line: it is gone from
// where it was and drawn one character further. The line that changed most, above the lowest
// skipBottom rows, is the caret's; on it, the leftmost run of changes, with gaps of at most gap
// samples, runs from the old caret to the new one.
func caretSpot(before: Samples, after: Samples, skipBottom: Int, gap maxGap: Int) -> (x: Int, y: Int, top: Int, bottom: Int, left: Int, right: Int)? {
    let columns = before.columns
    let rows = max(0, before.rows - skipBottom)
    var rowCounts = [Int](repeating: 0, count: rows)
    for row in 0..<rows {
        var count = 0
        for column in 0..<columns where before.values[row * columns + column] != after.values[row * columns + column] { count += 1 }
        rowCounts[row] = count
    }
    // Bands of rows that changed, allowing one quiet row inside a line of text.
    var best: (top: Int, bottom: Int, count: Int)?
    var row = 0
    while row < rows {
        guard rowCounts[row] > 0 else { row += 1; continue }
        let top = row
        var bottom = row
        var count = 0
        while row < rows, rowCounts[row] > 0 || (row + 1 < rows && rowCounts[row + 1] > 0) {
            if rowCounts[row] > 0 { bottom = row }
            count += rowCounts[row]
            row += 1
        }
        if bottom - top <= 30, best == nil || count > best!.count { best = (top, bottom, count) }
    }
    guard let band = best else { return nil }
    var changed = [Bool](repeating: false, count: columns)
    for row in band.top...band.bottom {
        for column in 0..<columns where before.values[row * columns + column] != after.values[row * columns + column] { changed[column] = true }
    }
    guard let left = changed.firstIndex(of: true) else { return nil }
    var right = left
    var gap = 0
    var column = left
    while column < columns, gap <= maxGap {
        if changed[column] { right = column; gap = 0 } else { gap += 1 }
        column += 1
    }
    return ((left + right) / 2, (band.top + band.bottom) / 2, band.top, band.bottom, left, right)
}

func press(_ press: Press, pid: pid_t) throws {
    try ensureInFront(pid: pid)
    let source = CGEventSource(stateID: .hidSystemState)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: press.code, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: press.code, keyDown: false)
    else { throw DriverError("cannot create a key event") }
    down.flags = press.flags
    up.flags = press.flags
    down.post(tap: .cghidEventTap)
    usleep(8000)
    up.post(tap: .cghidEventTap)
}

// MARK: Input sources

func inputSourceID(_ source: TISInputSource) -> String {
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

func selectInputSource(_ id: String) throws -> String {
    let current = inputSourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource], let source = list.first else {
        throw DriverError("input source \(id) is not enabled")
    }
    let status = TISSelectInputSource(source)
    if status != noErr { throw DriverError("cannot select input source \(id) (\(status))") }
    // An input method can accept the call and stay unselected; only the current source tells.
    for _ in 0..<20 {
        if inputSourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) == id { return current }
        usleep(50_000)
    }
    throw DriverError("input source \(id) did not become current; \(inputSourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())) is")
}

// MARK: Commands

let recorder = Recorder()

func sleep(ms: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(ms * 1e6))
}

// waitQuiet returns when no frame from index on changed by minPixels for quietMs, measured from
// `from`, and the ticks of the last such change (nil when none). With watch, it also checks every
// 100 ms that the recorded window is still on screen as attached, and stops with the reason when not.
func waitQuiet(from: UInt64, index: Int, minPixels: Int, quietMs: Double, timeoutMs: Double, needChange: Bool, baselineMin: Int?, watch pid: pid_t? = nil)
    async -> (first: UInt64?, last: UInt64?, frames: Int, maxChanged: Int, timedOut: Bool, disturbed: String?)
{
    var first: UInt64?
    var last: UInt64?
    var maxChanged = 0
    var seen = 0
    var checked = from
    while true {
        if let pid, milliseconds(mach_absolute_time() - checked) >= 100 {
            checked = mach_absolute_time()
            if let reason = disturbance(pid: pid, attached: recorder.attachedFrame) {
                return (first, last, seen, maxChanged, false, reason)
            }
        }
        let frames = recorder.frames(since: index)
        seen = frames.count
        first = nil
        last = nil
        maxChanged = 0
        for frame in frames where frame.ticks >= from {
            if let baselineMin, first == nil, frame.changedFromBaseline >= baselineMin { first = frame.ticks }
            if frame.changedFromPrevious >= minPixels { last = frame.ticks }
            maxChanged = max(maxChanged, frame.changedFromBaseline)
        }
        let now = mach_absolute_time()
        let quietSince = last ?? from
        let ready = !needChange || first != nil
        if ready && now > quietSince && milliseconds(now - quietSince) >= quietMs {
            return (first, last, seen, maxChanged, false, nil)
        }
        if milliseconds(now - from) >= timeoutMs { return (first, last, seen, maxChanged, true, nil) }
        await sleep(ms: 4)
    }
}

// Text Input Source and NSWorkspace calls belong on the main thread.
@MainActor
func handle(_ command: [String: Any]) async throws -> [String: Any] {
    let op = command["op"] as? String ?? ""
    let pid = pid_t(command["pid"] as? Int ?? 0)
    let minPixels = command["minPixels"] as? Int ?? 30
    let quietMs = command["quietMs"] as? Double ?? 500
    let timeoutMs = command["timeoutMs"] as? Double ?? 10000
    switch op {
    case "permissions":
        return [
            "accessibility": AXIsProcessTrusted(),
            "postEvents": CGPreflightPostEventAccess(),
            "screenCapture": CGPreflightScreenCaptureAccess(),
        ]
    case "input-source":
        guard let id = command["id"] as? String else { throw DriverError("input-source needs id") }
        return ["previous": try selectInputSource(id)]
    case "frontmost":
        return ["pid": Int(frontmostPid() ?? 0), "application": Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)]
    case "activate":
        try await activate(pid: pid)
        return [:]
    case "calm":
        let frame = try await waitCalm(pid: pid, stableMs: command["stableMs"] as? Double ?? 1000, timeoutMs: timeoutMs)
        return ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height]
    case "attach":
        await recorder.stop()
        // Recording is cut to the window's frame, so it starts only once that frame holds.
        _ = try await waitCalm(pid: pid, stableMs: command["stableMs"] as? Double ?? 1500, timeoutMs: timeoutMs)
        var window = try await recorder.start(pid: pid)
        await sleep(ms: 300)
        if let reason = disturbance(pid: pid, attached: recorder.attachedFrame) {
            await recorder.stop()
            throw DriverError("disturbed: \(reason)")
        }
        _ = try recorder.mark(baseline: false)
        window["frames"] = recorder.frames(since: 0).count
        return window
    case "keys":
        for key in try presses(command["keys"] as? [[String: Any]] ?? []) {
            try press(key, pid: pid)
            await sleep(ms: command["gapMs"] as? Double ?? 30)
        }
        return [:]
    case "quiet":
        let index = try recorder.mark(baseline: false)
        let start = mach_absolute_time()
        let result = await waitQuiet(from: start, index: index, minPixels: minPixels, quietMs: quietMs, timeoutMs: timeoutMs, needChange: false, baselineMin: nil)
        return ["ms": milliseconds(mach_absolute_time() - start), "timedOut": result.timedOut]
    case "point":
        try movePointer(to: CGPoint(x: command["x"] as? Double ?? 0, y: command["y"] as? Double ?? 0), pid: pid)
        return [:]
    case "locate":
        let keys = try presses(command["keys"] as? [[String: Any]] ?? [])
        guard let frame = recorder.attachedFrame, let before = recorder.samples() else { throw DriverError("not attached") }
        let index = try recorder.mark(baseline: true)
        defer { recorder.clearBaseline() }
        let start = mach_absolute_time()
        for key in keys {
            try press(key, pid: pid)
            await sleep(ms: 30)
        }
        let result = await waitQuiet(from: start, index: index, minPixels: minPixels, quietMs: quietMs, timeoutMs: timeoutMs, needChange: true, baselineMin: minPixels, watch: pid)
        if let reason = result.disturbed { throw DriverError("disturbed: \(reason); the caret was not found") }
        guard let after = recorder.samples(), after.columns == before.columns, after.rows == before.rows,
              let spot = caretSpot(before: before, after: after, skipBottom: Int((command["skipBottom"] as? Double ?? 0) / Double(recorder.step)), gap: 6)
        else { throw DriverError("the keys changed no line of text; the caret was not found") }
        let step = Double(recorder.step)
        return [
            "x": frame.minX + Double(spot.x) * step, "y": frame.minY + Double(spot.y) * step,
            "line": ["top": Double(spot.top) * step, "bottom": Double(spot.bottom) * step, "left": Double(spot.left) * step, "right": Double(spot.right) * step],
        ]
    case "measure":
        let keys = try presses(command["keys"] as? [[String: Any]] ?? [])
        let point = (command["point"] as? [String: Any]).map { CGPoint(x: $0["x"] as? Double ?? 0, y: $0["y"] as? Double ?? 0) }
        guard point != nil || !keys.isEmpty else { throw DriverError("measure needs a key or a point") }
        for key in point == nil ? Array(keys.dropLast()) : keys {
            try press(key, pid: pid)
            await sleep(ms: command["gapMs"] as? Double ?? 30)
        }
        if point != nil, let via = command["via"] as? [String: Any] {
            try movePointer(to: CGPoint(x: via["x"] as? Double ?? 0, y: via["y"] as? Double ?? 0), pid: pid)
            await sleep(ms: command["viaMs"] as? Double ?? 150)
        }
        let index = try recorder.mark(baseline: true)
        defer { recorder.clearBaseline() }
        let start = mach_absolute_time()
        if let point { try movePointer(to: point, pid: pid) } else { try press(keys.last!, pid: pid) }
        let result = await waitQuiet(from: start, index: index, minPixels: minPixels, quietMs: quietMs, timeoutMs: timeoutMs, needChange: true, baselineMin: minPixels, watch: pid)
        if let reason = result.disturbed { throw DriverError("disturbed: \(reason); the measurement does not count") }
        var answer: [String: Any] = ["timedOut": result.timedOut, "frames": result.frames, "maxChangedPixels": result.maxChanged]
        if let first = result.first { answer["firstMs"] = milliseconds(first - start) }
        if let changed = result.last { answer["settledMs"] = milliseconds(changed - start) }
        return answer
    case "snapshot":
        guard let file = command["file"] as? String else { throw DriverError("snapshot needs file") }
        try recorder.snapshot(to: file)
        return [:]
    default:
        throw DriverError("unknown op \(op)")
    }
}

func reply(_ object: [String: Any]) {
    var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{\"ok\":false}".utf8)
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

Task { @MainActor in
    do {
        for try await line in FileHandle.standardInput.bytes.lines {
            guard let data = line.data(using: .utf8),
                  let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                reply(["ok": false, "error": "not a JSON object: \(line)"])
                continue
            }
            do {
                var answer = try await handle(command)
                answer["ok"] = true
                reply(answer)
            } catch {
                reply(["ok": false, "error": "\(error)"])
            }
        }
    } catch {
        reply(["ok": false, "error": "stdin: \(error)"])
    }
    await recorder.stop()
    exit(0)
}
RunLoop.main.run()
