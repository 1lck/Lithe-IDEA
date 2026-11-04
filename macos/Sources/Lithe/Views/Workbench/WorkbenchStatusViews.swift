import LitheModuleAPI
import SwiftUI

/// Status bar line:column indicator. Visually unchanged from the plain text
/// label; clicking opens the Go to Line dialog (a no-op without an active
/// document).
struct EditorCaretPositionLabel: View {
    @ObservedObject var chrome: EditorChromeModel
    let onShowGoToLine: () -> Void

    var body: some View {
        Button {
            onShowGoToLine()
        } label: {
            Text(chrome.caret.map { "\($0.line + 1):\($0.utf16Column + 1)" } ?? "1:1")
                .monospacedDigit()
        }
        .buttonStyle(.litheNoPress)
        .lithePointer()
        .help("Go to Line…")
    }
}

/// Icon-only memory indicator: the status bar keeps just the chip so the
/// figures do not crowd the bar; hover shows the totals and a click opens the
/// detailed breakdown.
struct MemoryUsageStatusView: View {
    @EnvironmentObject private var memoryUsageMonitor: MemoryUsageMonitor
    @State private var isMemoryUsagePopoverPresented = false

    var body: some View {
        Button {
            isMemoryUsagePopoverPresented.toggle()
        } label: {
            Image(systemName: "memorychip")
        }
        .litheStatusBarIconButton()
        .accessibilityLabel(Text("Managed Memory"))
        .accessibilityValue(Text(memoryUsageMonitor.totalText))
        .help(
            Text(
                "Total managed memory: \(memoryUsageMonitor.totalText)\n" +
                "Lithe: \(memoryUsageMonitor.litheText) · LSP: \(memoryUsageMonitor.lspText) · Services: \(memoryUsageMonitor.serviceText)"
            )
        )
        .litheDropdown(isPresented: $isMemoryUsagePopoverPresented, opensUpward: true) {
            memoryUsagePopover
        }
        .onChange(of: isMemoryUsagePopoverPresented) { isPresented in
            memoryUsageMonitor.setDetailedUsageVisible(isPresented)
        }
    }

    private var memoryUsagePopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "memorychip")
                    .foregroundStyle(LitheTheme.accent)
                Text("Managed Memory")
                    .font(LitheTheme.uiFont(size: 12.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer(minLength: 8)
                Button {
                    isMemoryUsagePopoverPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(LitheTheme.uiFont(size: 10, weight: .semibold))
                }
                .litheIconButton()
                .help("Close")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            VStack(spacing: 0) {
                memoryMetric("Lithe", value: memoryUsageMonitor.litheText)
                memoryMetric(
                    "Language servers",
                    value: memoryUsageMonitor.languageServerProcessCount == 0
                        ? L10n.string("Not running")
                        : memoryUsageMonitor.lspText
                )
                memoryMetric(
                    "Running services",
                    value: memoryUsageMonitor.serviceProcessCount == 0
                        ? L10n.string("Not running")
                        : memoryUsageMonitor.serviceText
                )
                memoryMetric("Total", value: memoryUsageMonitor.totalText)
                memoryMetric("Average total", value: memoryUsageMonitor.averageText)
                memoryMetric("Peak total", value: memoryUsageMonitor.peakText)
                memoryMetric("Runtime", value: memoryUsageMonitor.runtimeText)
                memoryMetric("Sample interval", value: memoryUsageMonitor.samplingIntervalText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                Text("Resident memory of Lithe and its managed process trees")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(LitheTheme.smallFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(12)
        }
        .frame(width: 280)
    }

    private func memoryMetric(_ title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title))
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(LitheTheme.uiFont(size: 11.5, design: .monospaced))
                .foregroundStyle(LitheTheme.primaryText)
                .monospacedDigit()
        }
        .frame(minHeight: 27)
    }
}

/// Text-only frame rate readout; the "FPS" unit already names the metric.
struct FrameRateStatusView: View {
    @EnvironmentObject private var frameRateMonitor: FrameRateMonitor

    var body: some View {
        Text(frameRateMonitor.framesPerSecondText)
            .monospacedDigit()
            .help("Frames rendered per second")
            .accessibilityLabel(Text("\(frameRateMonitor.framesPerSecond) frames per second"))
    }
}

/// Observe the active document only; background split updates cannot replace its label.
struct EditorIndentationStatusLabel: View {
    @ObservedObject var document: EditorDocument

    var body: some View {
        if let indentation = document.indentation {
            if indentation.insertSpaces {
                Text("\(indentation.tabSize) spaces")
            } else {
                Text("Tab width: \(indentation.tabSize)")
            }
        }
    }
}
