#include "pch.h"
#include "App.xaml.h"
#include "MainWindow.xaml.h"

namespace winrt::Lithe::implementation {

App::App() {
    InitializeComponent();

#if defined(_DEBUG) && !defined(DISABLE_XAML_GENERATED_BREAK_ON_UNHANDLED_EXCEPTION)
    UnhandledException([](IInspectable const&, Microsoft::UI::Xaml::UnhandledExceptionEventArgs const& event) {
        if (IsDebuggerPresent()) {
            const auto message = event.Message();
            static_cast<void>(message);
            __debugbreak();
        }
    });
#endif
}

void App::OnLaunched(Microsoft::UI::Xaml::LaunchActivatedEventArgs const&) {
    window_ = make<MainWindow>();
    window_.Activate();
}

}
