#include "win32_archive_entry_reader.h"

#include <utility>

namespace lithe::windows {

Win32ArchiveEntryReader::Win32ArchiveEntryReader(ProcessRunner& runner)
    : runner_(runner) {}

std::optional<std::string> Win32ArchiveEntryReader::read(
    const std::string& archivePath,
    const std::string& entry) const {
    if (archivePath.empty() || entry.empty()) return std::nullopt;

    ProcessRequest request;
    request.operationID = "windows-archive-read";
    request.executablePath = "tar.exe";
    request.arguments = {"-xOf", archivePath, entry};
    request.timeoutMilliseconds = 10000;
    const auto result = runner_.run(request);
    if (!result.started || result.exitCode != 0) return std::nullopt;
    return result.output;
}

} // namespace lithe::windows
