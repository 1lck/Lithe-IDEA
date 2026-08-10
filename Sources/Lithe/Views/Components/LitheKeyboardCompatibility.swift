import AppKit
import SwiftUI

extension View {
    @ViewBuilder
    func litheOnReturn(perform action: @escaping (_ isShiftPressed: Bool) -> Void) -> some View {
        if #available(macOS 14.0, *) {
            onKeyPress(keys: [.return]) { press in
                action(press.modifiers.contains(.shift))
                return .handled
            }
        } else {
            onSubmit {
                action(NSEvent.modifierFlags.contains(.shift))
            }
        }
    }
}

struct LitheContentUnavailableView: View {
    let title: LocalizedStringKey
    let systemImage: String
    let description: Text?

    init(
        _ title: LocalizedStringKey,
        systemImage: String,
        description: Text? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 14.0, *) {
            ContentUnavailableView(title, systemImage: systemImage, description: description)
        } else {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 28))
                Text(title)
                    .font(.headline)
                description?
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .padding(24)
        }
    }
}
