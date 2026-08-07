#include "win32_authenticode_verifier.h"

#ifdef _WIN32

#include <windows.h>
#include <softpub.h>
#include <wintrust.h>

#include <string>

#endif

namespace lithe::windows {

bool Win32AuthenticodeVerifier::verify(const std::filesystem::path& file,
                                       std::string& error) const {
#ifndef _WIN32
    (void)file;
    error = "Authenticode verification requires Windows";
    return false;
#else
    const auto nativePath = file.wstring();
    if (nativePath.empty()) {
        error = "The installer path is empty";
        return false;
    }

    WINTRUST_FILE_INFO fileInfo{};
    fileInfo.cbStruct = sizeof(fileInfo);
    fileInfo.pcwszFilePath = nativePath.c_str();

    WINTRUST_DATA trustData{};
    trustData.cbStruct = sizeof(trustData);
    trustData.dwUIChoice = WTD_UI_NONE;
    trustData.fdwRevocationChecks = WTD_REVOKE_WHOLECHAIN;
    trustData.dwUnionChoice = WTD_CHOICE_FILE;
    trustData.pFile = &fileInfo;
    trustData.dwStateAction = WTD_STATEACTION_VERIFY;

    GUID policy = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    const auto status = WinVerifyTrust(nullptr, &policy, &trustData);
    trustData.dwStateAction = WTD_STATEACTION_CLOSE;
    WinVerifyTrust(nullptr, &policy, &trustData);
    if (status == ERROR_SUCCESS) return true;

    error = "Authenticode verification failed (WinVerifyTrust status " +
        std::to_string(static_cast<unsigned long>(status)) + ")";
    return false;
#endif
}

} // namespace lithe::windows
