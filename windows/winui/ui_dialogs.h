#pragma once

#include <winrt/Windows.Foundation.h>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>

namespace lithe::windows::winui {

// Centralizes the visual contract for the small confirmation and text-input
// dialogs used by the workbench. Complex feature state remains in MainWindow,
// while sizing, default-button safety, wrapping, and focus behavior stay
// consistent across Git and workspace commands.
class UiDialogs final {
public:
    static winrt::Windows::Foundation::IAsyncOperation<bool> confirm(
        winrt::Microsoft::UI::Xaml::XamlRoot const& xamlRoot,
        winrt::hstring title,
        winrt::hstring message,
        winrt::hstring primaryButton,
        winrt::hstring cancelButton,
        bool destructive = false);

    // An empty result means either cancellation or empty input. Callers already
    // reject empty Git references and names, so no separate sentinel is needed.
    static winrt::Windows::Foundation::IAsyncOperation<winrt::hstring> prompt(
        winrt::Microsoft::UI::Xaml::XamlRoot const& xamlRoot,
        winrt::hstring title,
        winrt::hstring fieldLabel,
        winrt::hstring primaryButton,
        winrt::hstring cancelButton,
        winrt::hstring initialValue = {},
        winrt::hstring placeholder = {});
};

} // namespace lithe::windows::winui
