#pragma once

#include "ports.h"

namespace lithe::windows {

// Windows 10 and later ship tar.exe.  It can read the ZIP archives shipped by
// a JDK without requiring a third-party DLL in the IDE installation.  The
// process runner still receives the archive name and entry as separate
// arguments, so archive paths and entry names cannot become shell syntax.
class Win32ArchiveEntryReader final : public ArchiveEntryReader {
public:
    explicit Win32ArchiveEntryReader(ProcessRunner& runner);

    std::optional<std::string> read(const std::string& archivePath,
                                    const std::string& entry) const override;

private:
    ProcessRunner& runner_;
};

} // namespace lithe::windows
