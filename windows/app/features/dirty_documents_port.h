#pragma once

#include <string>
#include <vector>

namespace lithe::windows::app {

/// Reads unsaved editor buffers so Git write preflight can block before disk-only
/// Git checks. W1 owns the real implementation; until that lands, tests and the
/// workbench use a fake that the UI (or tests) populate explicitly.
class DirtyDocumentsPort {
public:
    virtual ~DirtyDocumentsPort() = default;
    virtual std::vector<std::string> dirtyRelativePaths() const = 0;
};

class FakeDirtyDocumentsPort final : public DirtyDocumentsPort {
public:
    void setDirtyPaths(std::vector<std::string> paths) { paths_ = std::move(paths); }
    void clear() { paths_.clear(); }

    std::vector<std::string> dirtyRelativePaths() const override { return paths_; }

private:
    std::vector<std::string> paths_;
};

} // namespace lithe::windows::app
