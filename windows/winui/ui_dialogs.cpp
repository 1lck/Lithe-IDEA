#include "pch.h"
#include "ui_dialogs.h"

namespace lithe::windows::winui {

using namespace winrt::Microsoft::UI::Xaml;
using namespace winrt::Microsoft::UI::Xaml::Controls;

winrt::Windows::Foundation::IAsyncOperation<bool> UiDialogs::confirm(
    XamlRoot const& xamlRoot,
    winrt::hstring title,
    winrt::hstring message,
    winrt::hstring primaryButton,
    winrt::hstring cancelButton,
    bool destructive) {
    ContentDialog dialog;
    dialog.XamlRoot(xamlRoot);
    dialog.Title(winrt::box_value(std::move(title)));

    TextBlock body;
    body.Text(std::move(message));
    body.TextWrapping(TextWrapping::Wrap);
    body.MaxWidth(520);
    dialog.Content(body);

    dialog.PrimaryButtonText(std::move(primaryButton));
    dialog.CloseButtonText(std::move(cancelButton));
    dialog.DefaultButton(destructive ? ContentDialogButton::Close
                                     : ContentDialogButton::Primary);
    co_return co_await dialog.ShowAsync() == ContentDialogResult::Primary;
}

winrt::Windows::Foundation::IAsyncOperation<winrt::hstring> UiDialogs::prompt(
    XamlRoot const& xamlRoot,
    winrt::hstring title,
    winrt::hstring fieldLabel,
    winrt::hstring primaryButton,
    winrt::hstring cancelButton,
    winrt::hstring initialValue,
    winrt::hstring placeholder) {
    ContentDialog dialog;
    dialog.XamlRoot(xamlRoot);
    dialog.Title(winrt::box_value(std::move(title)));
    dialog.PrimaryButtonText(std::move(primaryButton));
    dialog.CloseButtonText(std::move(cancelButton));
    dialog.DefaultButton(ContentDialogButton::Primary);

    TextBox input;
    input.Header(winrt::box_value(std::move(fieldLabel)));
    input.MinWidth(360);
    input.MaxWidth(520);
    input.Text(std::move(initialValue));
    input.PlaceholderText(std::move(placeholder));
    if (!input.Text().empty()) input.SelectAll();
    dialog.Content(input);

    if (co_await dialog.ShowAsync() != ContentDialogResult::Primary) co_return winrt::hstring{};
    co_return input.Text();
}

} // namespace lithe::windows::winui
