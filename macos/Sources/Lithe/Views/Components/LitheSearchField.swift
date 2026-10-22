import SwiftUI

/// The single complete search entry: native IME editing, focus chrome, icon and clear action.
struct LitheSearchField<Accessory: View>: View {
    static var height: CGFloat { 36 }
    private let input: (FocusState<Bool>.Binding) -> AnyView
    private let label: Text
    @Binding private var text: String
    @FocusState private var isFocused: Bool
    private let activeFocus: () -> Bool?
    private let background: Color?
    private let onTextChanged: ((String) -> Void)?
    private let fieldTitle: Text?
    private let info: String?
    private let isEnabled: Bool
    private let accessory: Accessory

    init(_ placeholder: LocalizedStringKey, text: Binding<String>, focus: FocusState<Bool>.Binding? = nil,
         background: Color? = nil, onTextChanged: ((String) -> Void)? = nil,
         @ViewBuilder accessory: () -> Accessory) {
        input = { AnyView(LitheSearchTextField(placeholder, text: text).focused(focus ?? $0)) }
        label = Text(placeholder); _text = text; activeFocus = { focus?.wrappedValue }
        self.background = background; self.onTextChanged = onTextChanged
        fieldTitle = nil; info = nil; isEnabled = true
        self.accessory = accessory()
    }

    init(_ placeholder: LocalizedStringKey, text: Binding<String>, focus: FocusState<Bool>.Binding? = nil,
         background: Color? = nil, onTextChanged: ((String) -> Void)? = nil) where Accessory == EmptyView {
        self.init(placeholder, text: text, focus: focus, background: background,
                  onTextChanged: onTextChanged, accessory: { EmptyView() })
    }

    init(label: String, placeholder: String, text: Binding<String>, info: String? = nil,
         isEnabled: Bool = true) where Accessory == EmptyView {
        input = { AnyView(LitheSearchTextField(verbatim: placeholder, text: text).focused($0)) }
        self.label = Text(verbatim: label); _text = text; activeFocus = { nil }
        background = nil; onTextChanged = nil; fieldTitle = Text(verbatim: label)
        self.info = info; self.isEnabled = isEnabled; accessory = EmptyView()
    }

    init<Value: Hashable>(_ placeholder: LocalizedStringKey, text: Binding<String>,
                          focus: FocusState<Value?>.Binding, equals value: Value) where Accessory == EmptyView {
        input = { _ in AnyView(LitheSearchTextField(placeholder, text: text).focused(focus, equals: value)) }
        label = Text(placeholder); _text = text; activeFocus = { focus.wrappedValue == value }
        background = nil; onTextChanged = nil; fieldTitle = nil; info = nil; isEnabled = true
        accessory = EmptyView()
    }

    var body: some View {
        LitheFormField(title: fieldTitle, info: info, isEnabled: isEnabled) {
            HStack(spacing: 7) {
                LitheIDEAIcon(resourcePath: "expui/general/search.svg", size: LitheTheme.Tree.iconSize,
                              preservesOriginalColors: true).accessibilityHidden(true)
                input($isFocused).accessibilityLabel(label)
                if !text.isEmpty {
                    Button { text = "" } label: {
                        LitheIDEAIcon(resourcePath: "expui/general/close.svg", size: LitheTheme.Tree.iconSize)
                    }
                    .litheToolbarIconButton()
                    .accessibilityLabel(Text("Clear search"))
                    .help("Clear search")
                }
                accessory
            }
            .litheSearchField(isFocused: activeFocus() ?? isFocused, background: background)
            .onChange(of: text) { onTextChanged?($0) }
        }
    }
}
