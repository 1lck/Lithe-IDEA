#include "pch.h"
#include "App.xaml.h"
#include "MainWindow.xaml.h"

namespace winrt::Lithe::implementation {

namespace {

void WriteStartupError(winrt::hstring const& message) {
    const auto path = std::filesystem::temp_directory_path() / L"lithe-winui-error.log";
    if (const auto file = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                                      OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        file != INVALID_HANDLE_VALUE) {
        SetFilePointer(file, 0, nullptr, FILE_END);
        const auto bytes = static_cast<DWORD>(message.size() * sizeof(wchar_t));
        DWORD written = 0;
        WriteFile(file, message.c_str(), bytes, &written, nullptr);
        constexpr wchar_t newline[] = L"\r\n";
        WriteFile(file, newline, sizeof(newline) - sizeof(wchar_t), &written, nullptr);
        CloseHandle(file);
    }
}

}

App::App() {
    InitializeComponent();

    UnhandledException([](IInspectable const&, Microsoft::UI::Xaml::UnhandledExceptionEventArgs const& event) {
        WriteStartupError(event.Message());
#if defined(_DEBUG) && !defined(DISABLE_XAML_GENERATED_BREAK_ON_UNHANDLED_EXCEPTION)
        if (IsDebuggerPresent()) {
            __debugbreak();
        }
#endif
    });
}

void App::OnLaunched(Microsoft::UI::Xaml::LaunchActivatedEventArgs const&) {
    try {
        WriteStartupError(L"OnLaunched: creating window");
        window_ = make<MainWindow>();
        WriteStartupError(L"OnLaunched: window created");
        window_.Activate();
        WriteStartupError(L"OnLaunched: window activated");
    } catch (winrt::hresult_error const& error) {
        WriteStartupError(error.message());
        throw;
    }
}

}
