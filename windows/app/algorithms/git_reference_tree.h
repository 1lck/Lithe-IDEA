#pragma once

#include <optional>
#include <string>
#include <vector>

namespace lithe::windows::algorithms {

struct GitReferenceInfo {
    std::string fullName;
    std::string shortName;
    std::string kind;
    bool isCurrent = false;
    std::optional<std::string> upstreamShortName;
};

struct GitReferenceTreeNode {
    std::string path;
    std::string name;
    std::optional<GitReferenceInfo> reference;
    std::vector<GitReferenceTreeNode> children;
};

std::vector<GitReferenceTreeNode> buildGitReferenceTree(
    const std::vector<GitReferenceInfo>& references);

} // namespace lithe::windows::algorithms
