import AppKit
import SwiftUI
import LitheModuleAPI

/// Dates are local presentation values; the existing model sends UTC bounds to Core.
struct LogTimeRangePicker: View {
    @ObservedObject var model: LogWindowModel
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 5) {
                Text("Time range")
                if let since = date(model.query.since), let until = date(model.query.until) {
                    Text(verbatim: label(since) + " – " + label(until))
                }
            }
        }
        .accessibilityIdentifier("logs.time-range")
        .overlay {
            LitheDropdownPopover(isPresented: $isPresented) {
                LogTimeRangeEditor(
                    start: date(model.query.since) ?? model.state.records.first.map { Date(timeIntervalSince1970: Double($0.epochMs) / 1000) } ?? Date(),
                    end: date(model.query.until) ?? model.state.records.last.map { Date(timeIntervalSince1970: Double($0.epochMs) / 1000) } ?? Date(),
                    apply: { start, end in
                        model.setRange(since: Int64(start.timeIntervalSince1970.rounded(.down)) * 1000,
                            until: Int64(end.timeIntervalSince1970.rounded(.down)) * 1000 + 999)
                        isPresented = false
                    }, clear: {
                        model.changeQuery { $0.since = nil; $0.until = nil }
                        isPresented = false
                    })
            }
        }
    }
    private func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
    private func label(_ date: Date) -> String {
        date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }
}

private struct LogTimeRangeEditor: View {
    @State var start: Date
    @State var end: Date
    let apply: (Date, Date) -> Void
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Time range")
                LitheInfoTip("logs.window.timeHelp")
            }
            HStack(alignment: .top, spacing: 16) {
                endpoint("Start time", date: $start)
                endpoint("End time", date: $end)
            }
            Text(verbatim: TimeZone.current.localizedName(for: .standard, locale: InterfaceLanguage.locale) ?? TimeZone.current.identifier)
                .font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.secondaryText)
            if start > end { Text("The end time must be after the start time.").foregroundStyle(LitheTheme.error) }
            HStack {
                Button("Clear time range", action: clear)
                    .accessibilityIdentifier("logs.clear-time-range")
                Spacer()
                Button("Apply") { apply(start, end) }.disabled(start > end)
                    .accessibilityIdentifier("logs.apply-time-range")
            }
        }.padding(12).frame(width: 536).font(LitheTheme.uiFont(size: 12))
    }
    private func endpoint(_ title: LocalizedStringKey, date: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            LogNativeDatePicker(date: date, calendar: true).frame(width: 248, height: 150)
            LogNativeDatePicker(date: date, calendar: false).frame(width: 248, height: 26)
        }
    }
}

private struct LogNativeDatePicker: NSViewRepresentable {
    @Binding var date: Date
    let calendar: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = calendar ? .clockAndCalendar : .textFieldAndStepper
        picker.datePickerElements = calendar ? .yearMonthDay : .hourMinuteSecond
        picker.timeZone = .current
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        return picker
    }
    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.parent = self
        picker.locale = InterfaceLanguage.locale
        if picker.dateValue != date { picker.dateValue = date }
    }
    @MainActor final class Coordinator: NSObject {
        var parent: LogNativeDatePicker
        init(_ parent: LogNativeDatePicker) { self.parent = parent }
        @objc func changed(_ picker: NSDatePicker) { parent.date = picker.dateValue }
    }
}
