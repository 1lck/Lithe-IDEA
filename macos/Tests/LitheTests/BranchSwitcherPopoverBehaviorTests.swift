import Foundation
import Testing
@testable import Lithe

/// Guards the branch popup's IDEA-aligned interaction contract. The rows are
/// SwiftUI views without a testable state surface, so these checks read the
/// source: the regression they protect against is a branch row silently going
/// back to checking out on a plain click, which switches the working tree from
/// a stray click while scanning the list.
@Suite("Branch switcher popover behavior")
struct BranchSwitcherPopoverBehaviorTests {
    private static func popoverSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let popoverURL = repositoryRoot.appendingPathComponent(
            "Sources/Lithe/Views/Git/BranchSwitcherPopover.swift"
        )
        return try String(contentsOf: popoverURL, encoding: .utf8)
    }

    @Test
    func branchRowsOpenAnActionMenuInsteadOfCheckingOutOnClick() throws {
        let source = try Self.popoverSource()

        #expect(
            source.contains("BranchActionMenuRow("),
            "Branch rows must route through BranchActionMenuRow so a click opens the action menu."
        )
        #expect(
            source.contains("private func branchActionMenu(for reference: GitReference)"),
            "The per-reference action list must exist for the menu to present."
        )
    }

    @Test
    func checkoutIsReachableOnlyAsAnExplicitMenuEntry() throws {
        let source = try Self.popoverSource()

        // The single permitted checkout call site is the menu's Checkout entry.
        let checkoutCallSites = source.components(separatedBy: "model.checkoutReference(").count - 1
        #expect(
            checkoutCallSites == 1,
            "Checkout must have exactly one call site, the explicit Checkout menu entry."
        )

        guard let checkoutRange = source.range(of: "model.checkoutReference(") else {
            Issue.record("Expected a checkout call site in the branch popup.")
            return
        }
        let precedingSource = source[source.startIndex..<checkoutRange.lowerBound]
        guard let buttonRange = precedingSource.range(of: "Button(\"Checkout\")", options: .backwards) else {
            Issue.record("Checkout must be invoked from a Button labelled Checkout.")
            return
        }
        // Nothing but the dismiss-and-run wrapper may sit between the button and
        // the checkout call, which keeps the call attached to that menu entry.
        let between = precedingSource[buttonRange.upperBound...]
        #expect(
            between.contains("dismissAndRun"),
            "The Checkout menu entry must dismiss the popup before checking out."
        )
        #expect(
            !between.contains("Button("),
            "No other button may sit between the Checkout entry and the checkout call."
        )
    }

    @Test
    func truncatedBranchRowsExposeTheirFullNameOnHover() throws {
        let source = try Self.popoverSource()

        #expect(
            source.contains(".help(branchRowTooltip(reference))"),
            "Rows truncate branch and upstream names, so hover must reveal the untruncated pair."
        )
    }
}
