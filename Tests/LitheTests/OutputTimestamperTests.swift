import AppKit
import Foundation
import Testing

@testable import Lithe

@Suite("Output timestamping")
struct OutputTimestamperTests {
    private let noon = Date(timeIntervalSince1970: 0)

    /// Maven's `[INFO]` lines carry no clock, which is exactly the output that
    /// leaves "when did this stall" unanswerable.
    @Test
    func stampsLinesThatHaveNoClockOfTheirOwn() {
        let stamped = OutputTimestamper.stamped(
            "[INFO] Building backend-api\n[ERROR] Port in use\n",
            continuingLine: false,
            now: noon
        )
        let lines = stamped.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0].hasSuffix("[INFO] Building backend-api"))
        #expect(lines[1].hasSuffix("[ERROR] Port in use"))
        #expect(OutputTimestamper.hasLeadingTime(String(lines[0])))
        #expect(OutputTimestamper.hasLeadingTime(String(lines[1])))
    }

    /// Spring Boot prints its own timestamp; a second one would just be noise.
    @Test
    func leavesLinesThatAlreadyCarryATimestampAlone() {
        let line = "2026-08-08T10:12:33.123  INFO 1 --- [main] Started App"
        let stamped = OutputTimestamper.stamped(line + "\n", continuingLine: false, now: noon)
        #expect(stamped == line + "\n")
    }

    /// A chunk boundary can land mid-line. Stamping there would inject a clock
    /// into the middle of a message.
    @Test
    func doesNotStampAContinuationOfAPartialLine() {
        let stamped = OutputTimestamper.stamped("rest of message\n", continuingLine: true, now: noon)
        #expect(stamped == "rest of message\n")
    }

    /// A chunk that ends without a newline must not gain one, or the next
    /// chunk's continuation would be pushed onto its own line.
    @Test
    func preservesWhetherTheChunkEndedWithANewline() {
        let stamped = OutputTimestamper.stamped("partial", continuingLine: false, now: noon)
        #expect(!stamped.hasSuffix("\n"))
        #expect(stamped.hasSuffix("partial"))
    }

    @Test
    func doesNotStampBlankLines() {
        let stamped = OutputTimestamper.stamped("\n\n", continuingLine: false, now: noon)
        #expect(stamped == "\n\n")
    }

    /// The dimmed gutter has to cover the fractional seconds too, otherwise the
    /// milliseconds stay bright while the hours recede.
    @Test
    func measuresTheWholeClockIncludingFractionalSeconds() throws {
        let length = try #require(
            OutputTimestamper.leadingTimeLength(of: "10:12:33.123 [INFO] hello")
        )
        #expect(length == "10:12:33.123 ".count)
    }

    @Test
    func reportsNoClockForAPlainLine() {
        #expect(OutputTimestamper.leadingTimeLength(of: "[INFO] hello") == nil)
    }
}

@Suite("Output severity coloring")
@MainActor
struct OutputSeverityTests {
    @Test
    func recognizesBracketedMavenLevels() {
        #expect(OutputTextView.severity(ofLine: "[ERROR] Failed to execute goal") == .error)
        #expect(OutputTextView.severity(ofLine: "[WARNING] deprecated API") == .warning)
        #expect(OutputTextView.severity(ofLine: "[INFO] Building") == .info)
    }

    @Test
    func recognizesSpringBootSpacedLevels() {
        let line = "2026-08-08T10:12:33.123  WARN 1 --- [main] Port 8081 was already in use"
        #expect(OutputTextView.severity(ofLine: line) == .warning)
    }

    /// A path segment that merely contains the word must not paint the line red,
    /// or every stack trace through an `Error.java` reads as a failure.
    @Test
    func ignoresLevelWordsEmbeddedInPaths() {
        #expect(OutputTextView.severity(ofLine: "  at src/main/java/ErrorHandler.java:42") == nil)
        #expect(OutputTextView.severity(ofLine: "Compiling Information.kt") == nil)
    }

    @Test
    func reportsNoSeverityForOrdinaryOutput() {
        #expect(OutputTextView.severity(ofLine: "Tomcat started on port 8081") == nil)
    }
}

@Suite("ANSI output colors")
@MainActor
struct ANSIOutputColorTests {
    /// Maven commonly emits bold/reset SGR codes without choosing a foreground
    /// color. The fallback must be resolved for the tool window's appearance;
    /// leaving it as an adaptive SwiftUI color turns it black when bridged into
    /// an AppKit text storage under the dark theme.
    @Test
    func darkAppearanceResolvesDefaultForegroundBeforeAppKitBridging() throws {
        let foreground = LitheTheme.nsColor(.primaryText, theme: .lithe, isDark: true)
        let parsed = ANSIOutputRenderer.parse(
            "\u{1B}[1m[INFO] Building\u{1B}[0m\n",
            defaultForeground: foreground
        )
        let rendered = ANSIOutputRenderer.render(parsed, fontSize: 11.5)
        let color = try #require(
            (rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?
                .usingColorSpace(.sRGB)
        )

        #expect(color.brightnessComponent > 0.75)
    }
}

@Suite("Output text updates")
struct OutputTextUpdateTests {
    @Test
    func appendsOnlyTheNewCompleteLines() {
        #expect(
            OutputTextUpdate.plan(
                previous: "first\n",
                next: "first\nsecond\n",
                previousHadANSI: false
            ) == .append("second\n")
        )
    }

    @Test
    func leavesUnchangedOutputAlone() {
        #expect(
            OutputTextUpdate.plan(previous: "same", next: "same", previousHadANSI: false) == .unchanged
        )
    }

    @Test
    func replacesTruncatedOrRewrittenOutput() {
        #expect(OutputTextUpdate.plan(previous: "old\n", next: "new\n", previousHadANSI: false) == .replace)
        #expect(OutputTextUpdate.plan(previous: "old\nline\n", next: "line\n", previousHadANSI: false) == .replace)
    }

    @Test
    func redrawsOnlyTheIncompleteTrailingLine() {
        #expect(
            OutputTextUpdate.plan(
                previous: "complete\npartial",
                next: "complete\npartial line\n",
                previousHadANSI: false
            ) == .replaceTail(length: 7, with: "partial line\n")
        )
    }

    @Test
    func replacesWhenANSIStateCouldCrossTheBoundary() {
        #expect(OutputTextUpdate.plan(previous: "\u{1B}[31mred\n", next: "\u{1B}[31mred\nmore\n", previousHadANSI: true) == .replace)
    }
}
