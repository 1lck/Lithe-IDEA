#include "windows_chrome.h"

#ifdef _WIN32
#include <dwmapi.h>
#include <windows.h>

namespace {

COLORREF colorRef(unsigned int red, unsigned int green, unsigned int blue) {
    return RGB(red, green, blue);
}

bool setAttribute(HWND hwnd, DWORD attribute, const void* value, DWORD size) {
    return SUCCEEDED(DwmSetWindowAttribute(hwnd, attribute, value, size));
}

}  // namespace
#endif

namespace lithe::windows {

void applyWindowsWindowChrome(QWidget& window) {
#ifdef _WIN32
    // winId() creates the HWND before DWM attributes are applied, which also
    // makes this work reliably when called before QWidget::show().
    const auto hwnd = reinterpret_cast<HWND>(window.winId());
    if (hwnd == nullptr) return;

    const BOOL darkMode = TRUE;
    // Windows 11 uses attribute 20; Windows 10 builds that shipped the
    // earlier contract use 19. Setting both is harmless on newer systems.
    setAttribute(hwnd, 20, &darkMode, sizeof(darkMode));
    setAttribute(hwnd, 19, &darkMode, sizeof(darkMode));

    const COLORREF caption = colorRef(43, 45, 48); // #2B2D30
    const COLORREF border = colorRef(60, 63, 67);  // #3C3F43
    const COLORREF text = colorRef(217, 217, 218); // #D9D9DA
    setAttribute(hwnd, 35, &caption, sizeof(caption));
    setAttribute(hwnd, 34, &border, sizeof(border));
    setAttribute(hwnd, 36, &text, sizeof(text));
#else
    Q_UNUSED(window);
#endif
}

}  // namespace lithe::windows
