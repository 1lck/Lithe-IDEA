#include <windows.h>
#include <shellapi.h>

#include <filesystem>
#include <cstdint>
#include <string>

namespace {

struct Arguments {
    DWORD processID = 0;
    std::wstring installer;
};

Arguments parseArguments(int argc, wchar_t** argv) {
    Arguments result;
    for (int index = 1; index + 1 < argc; ++index) {
        const std::wstring option = argv[index];
        if (option == L"--pid") {
            result.processID = static_cast<DWORD>(wcstoul(argv[++index], nullptr, 10));
        } else if (option == L"--installer") {
            result.installer = argv[++index];
        }
    }
    return result;
}

int run(const Arguments& arguments) {
    if (arguments.processID == 0 || arguments.installer.empty()) return 2;

    HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, arguments.processID);
    if (process != nullptr) {
        const auto waitResult = WaitForSingleObject(process, INFINITE);
        CloseHandle(process);
        if (waitResult != WAIT_OBJECT_0) return 3;
    } else if (GetLastError() != ERROR_INVALID_PARAMETER) {
        return 3;
    }

    const auto workingDirectory = std::filesystem::path(arguments.installer).parent_path();
    const auto workingDirectoryText = workingDirectory.empty()
        ? std::wstring{}
        : workingDirectory.wstring();
    const auto launched = ShellExecuteW(
        nullptr, L"open", arguments.installer.c_str(), nullptr,
        workingDirectoryText.empty() ? nullptr : workingDirectoryText.c_str(), SW_SHOWNORMAL);
    if (reinterpret_cast<std::intptr_t>(launched) <= 32) {
        return 4;
    }
    return 0;
}

} // namespace

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
    int argc = 0;
    auto* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (argv == nullptr) return 2;
    const auto result = run(parseArguments(argc, argv));
    LocalFree(argv);
    return result;
}
