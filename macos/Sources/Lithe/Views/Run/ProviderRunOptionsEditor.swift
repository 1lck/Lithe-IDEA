import LitheCoreContracts
import SwiftUI

/// Each row remains one argument. Quotes, whitespace and empty values are
/// ordinary provider data, not a command line the view interprets.
struct ProviderRunOptionsEditor: View {
    @Binding var value: BuildProviderRunOptions?

    private var arguments: [String] { value?.runtimeArguments ?? [] }
    private func update(_ edit: (inout BuildProviderRunOptions) -> Void) {
        var next = value ?? BuildProviderRunOptions()
        edit(&next)
        value = next
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("Runtime arguments")
                    .font(LitheTheme.uiFont(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                LitheInfoTip("Each row is one argument. Spaces, quotes and empty values are preserved.")
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(arguments.indices), id: \.self) { index in
                        HStack(spacing: 4) {
                            LitheTextEditor(text: Binding(
                                get: { arguments.indices.contains(index) ? arguments[index] : "" },
                                set: { text in update { if $0.runtimeArguments.indices.contains(index) { $0.runtimeArguments[index] = text } } }
                            ), height: 22)
                            .accessibilityLabel(Text("Runtime arguments"))
                            Button { update { if $0.runtimeArguments.indices.contains(index) { $0.runtimeArguments.remove(at: index) } } } label: {
                                Image(systemName: "minus")
                            }
                            .litheIconButton()
                            .help("Remove")
                        }
                        .frame(height: 32)
                    }
                }
            }
            .frame(height: CGFloat(min(arguments.count, 6)) * 36)
            .litheScrollViewChrome(hideHorizontal: true)
            Button { update { $0.runtimeArguments.append("") } } label: {
                Label("Add argument", systemImage: "plus")
            }
            .buttonStyle(LitheActionButtonStyle())
            .disabled(arguments.count >= 1024)
            Text("Entry point")
                .font(LitheTheme.uiFont(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
            LitheTextField("", text: Binding(get: { value?.entrypoint ?? "" }, set: { text in update { $0.entrypoint = text } }))
                .accessibilityLabel(Text("Entry point"))
        }
    }
}
