#include "pch.h"
#include "App.xaml.h"
#include "MainWindow.xaml.h"

namespace winrt::Lithe::implementation {

App::App() {
    InitializeComponent();

    UnhandledException([](IInspectable const&, Microsoft::UI::Xaml::UnhandledExceptionEventArgs const& event) {
        const auto path = std::filesystem::temp_directory_path() / L"lithe-winui-error.log";
        if (const auto file = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                                          CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            file != INVALID_HANDLE_VALUE) {
            const auto message = event.Message();
            const auto bytes = static_cast<DWORD>(message.size() * sizeof(wchar_t));
            DWORD written = 0;
            WriteFile(file, message.c_str(), bytes, &written, nullptr);
            CloseHandle(file);
        }
#if defined(_DEBUG) && !defined(DISABLE_XAML_GENERATED_BREAK_ON_UNHANDLED_EXCEPTION)
        if (IsDebuggerPresent()) {
            __debugbreak();
        }
#endif
    });
}

void App::OnLaunched(Microsoft::UI::Xaml::LaunchActivatedEventArgs const&) {
    window_ = make<MainWindow>();
    window_.Activate();
}

}
