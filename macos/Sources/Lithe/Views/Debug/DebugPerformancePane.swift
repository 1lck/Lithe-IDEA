import Charts
import SwiftUI

struct DebugConsoleWithPerformance<Console: View>: View {
    @ObservedObject var feature: DebugPerformanceFeatureModel
    @Binding var isExpanded: Bool
    @Binding var width: CGFloat
    var residentMemory = false
    @ViewBuilder let console: () -> Console
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredTime: TimeInterval?

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                LitheSplitPaneView(axis: .horizontal, placement: .trailing,
                    defaultSize: width, minimum: 240, maximum: max(240, geometry.size.width - 300),
                    flexibleMinimum: 300, clipsSizedPane: true, isSizedPaneCollapsed: !isExpanded,
                    dividerColor: LitheTheme.toolWindowBorder(for: colorScheme), onCommit: { width = $0 }) {
                    performance
                } flexible: { console() }
                if !isExpanded {
                    LitheCollapsedActionStripe(title: "Performance", expandsToward: .leading) { isExpanded = true }
                        .litheWorkbenchSurface(LitheTheme.sidebar)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(LitheTheme.toolWindowBorder(for: colorScheme)).frame(width: 1)
                        }
                }
            }
        }
        .onAppear { feature.setVisible(isExpanded) }
        .onChange(of: isExpanded) { feature.setVisible($0) }
        .onChange(of: feature.samples.last?.timestamp) { [previous = feature.samples.last?.timestamp] current in
            if let previous, let current, current >= previous, let time = hoveredTime {
                hoveredTime = time + current - previous
            } else { hoveredTime = nil }
        }
        .onDisappear { feature.setVisible(false); hoveredTime = nil }
    }

    private var performance: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Performance").font(LitheTheme.ActionStripe.titleFont).foregroundStyle(LitheTheme.ActionStripe.titleColor)
                Spacer()
                Button { isExpanded = false } label: {
                    LitheIDEAIcon(resourcePath: "expui/general/chevronRight.svg", size: 16, preservesOriginalColors: true)
                }
                .litheToolbarIconButton()
                .help("Hide Performance")
            }
            .padding(.horizontal, 10)
            .frame(height: LitheTheme.Metrics.toolbarHeight)
            LitheToolWindowHeaderDivider()
            if let message = feature.errorMessage {
                Text(LocalizedStringKey(message)).font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            } else if feature.samples.isEmpty {
                Text(LocalizedStringKey(feature.isSampling
                    ? (residentMemory ? "Waiting for process performance data…" : "Waiting for JVM performance data…")
                    : (residentMemory ? "Run tests to view process performance." : "Start a local Java debug session to view performance.")))
                    .font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            DebugPerformanceChart(samples: feature.samples, cpu: true, residentMemory: residentMemory, hoveredTime: $hoveredTime)
            DebugPerformanceChart(samples: feature.samples, cpu: false, residentMemory: residentMemory, hoveredTime: $hoveredTime)
            if residentMemory {
                Text("Test process tree · Resident memory")
                    .font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            Spacer(minLength: 0)
        }
        .litheWorkbenchSurface(LitheTheme.editor)
    }
}

/// Both metrics share the hovered sample so the time cursor stays aligned.
struct DebugPerformanceChart: View {
    static let maximumHeight: CGFloat = 160
    static let visibleDuration: TimeInterval = 60
    let samples: [DebugPerformanceSample]
    let cpu: Bool
    var residentMemory = false
    @Binding var hoveredTime: TimeInterval?
    @Environment(\.colorScheme) private var colorScheme

    private var title: String { cpu ? "CPU" : (residentMemory ? "Resident Memory" : "Heap Memory") }
    private var color: Color { cpu ? LitheTheme.success : LitheTheme.accent }
    private var selected: DebugPerformanceSample? {
        hoveredTime.flatMap { Self.nearestSample(in: visibleSamples, to: $0) } ?? samples.last
    }
    private var timeDomain: ClosedRange<Double> {
        Self.timeDomain(latestTimestamp: samples.last?.timestamp ?? 0)
    }
    private var visibleSamples: [DebugPerformanceSample] {
        samples.filter { timeDomain.contains($0.timestamp) }
    }

    static func timeDomain(latestTimestamp: TimeInterval) -> ClosedRange<Double> {
        (latestTimestamp - visibleDuration)...latestTimestamp
    }

    static func nearestSample(in samples: [DebugPerformanceSample], to time: TimeInterval) -> DebugPerformanceSample? {
        guard time.isFinite else { return nil }
        // Histories are capped at 600 samples by the feature owner.
        return samples.min { abs($0.timestamp - time) < abs($1.timestamp - time) }
    }

    private func number(_ sample: DebugPerformanceSample) -> Double? {
        cpu ? sample.cpuPercent : Double(sample.memoryUsedBytes)
    }

    private func formatted(_ sample: DebugPerformanceSample?) -> String {
        guard let sample else { return "—" }
        return cpu ? sample.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—"
            : ByteCountFormatter.string(fromByteCount: Int64(clamping: sample.memoryUsedBytes), countStyle: .memory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Reserve space for the hover readout; it must not move the plot.
            HStack {
                Spacer(minLength: 0)
                if let selected, hoveredTime != nil {
                    Text(Duration.seconds(selected.timestamp).formatted(.time(pattern: .minuteSecond)))
                }
            }
            .font(LitheTheme.uiFont(size: 12))
            .monospacedDigit()
            .foregroundStyle(LitheTheme.primaryText)
            .frame(height: 18)
            Chart {
                ForEach(visibleSamples) { sample in
                    if let value = number(sample) {
                        AreaMark(x: .value("Uptime", sample.timestamp),
                                 yStart: .value(title, 0), yEnd: .value(title, value))
                            .foregroundStyle(color.opacity(0.12))
                        LineMark(x: .value("Uptime", sample.timestamp), y: .value(title, value))
                            .lineStyle(StrokeStyle(lineWidth: 1)).foregroundStyle(color)
                    }
                }
                if let selected, let value = number(selected) {
                    if hoveredTime != nil {
                        RuleMark(x: .value("Uptime", selected.timestamp))
                            .foregroundStyle(LitheTheme.toolWindowBorder(for: colorScheme))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                    PointMark(x: .value("Uptime", selected.timestamp), y: .value(title, value))
                        .symbolSize(30).foregroundStyle(color)
                        .annotation(position: .top, alignment: .trailing, spacing: 4) {
                            Text(formatted(selected))
                                .font(LitheTheme.uiFont(size: 12)).monospacedDigit()
                                .foregroundStyle(LitheTheme.primaryText)
                        }
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartXScale(domain: timeDomain, range: .plotDimension(padding: 0))
            .chartYScale(domain: 0...(cpu ? 100 : max(1, Double(visibleSamples.map(\.memoryCapacityBytes).max() ?? 1))))
            .chartPlotStyle { plot in
                plot.background(alignment: .bottom) {
                    Rectangle().fill(LitheTheme.toolWindowBorder(for: colorScheme)).frame(height: 1)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let frame = geometry[proxy.plotAreaFrame]
                                if frame.contains(location),
                                   let time: Double = proxy.value(atX: location.x - frame.minX),
                                   let sample = Self.nearestSample(in: visibleSamples, to: time) {
                                    if hoveredTime != sample.timestamp { hoveredTime = sample.timestamp }
                                } else { hoveredTime = nil }
                            case .ended: hoveredTime = nil
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(LocalizedStringKey(title))
            .accessibilityValue(formatted(selected))
            Text(LocalizedStringKey(title))
                .font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(maxHeight: Self.maximumHeight)
    }
}
