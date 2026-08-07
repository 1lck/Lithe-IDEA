#include "git_graph_layout.h"

#include <algorithm>
#include <set>
#include <string_view>

namespace lithe::windows::algorithms {
namespace {

struct Lane {
    std::string hash;
    std::size_t colorIndex = 0;
};

std::string trim(std::string value) {
    const auto isSpace = [](unsigned char character) { return character == ' ' || character == '\t' || character == '\r' || character == '\n'; };
    while (!value.empty() && isSpace(static_cast<unsigned char>(value.front()))) value.erase(value.begin());
    while (!value.empty() && isSpace(static_cast<unsigned char>(value.back()))) value.pop_back();
    return value;
}

std::vector<GitGraphLabel> labels(std::string_view decorations) {
    std::vector<GitGraphLabel> result;
    std::size_t start = 0;
    while (start <= decorations.size()) {
        const auto end = decorations.find(',', start);
        auto raw = trim(std::string(decorations.substr(
            start, end == std::string_view::npos ? decorations.size() - start : end - start)));
        if (!raw.empty()) {
            if (raw == "HEAD") {
                result.push_back({"HEAD", GitGraphReferenceKind::Head});
            } else if (raw.rfind("HEAD -> ", 0) == 0) {
                result.push_back({"HEAD", GitGraphReferenceKind::Head});
                result.push_back({raw.substr(8), GitGraphReferenceKind::Branch});
            } else if (raw.rfind("tag: ", 0) == 0) {
                result.push_back({raw.substr(5), GitGraphReferenceKind::Tag});
            } else if (raw.rfind("refs/tags/", 0) == 0) {
                result.push_back({raw.substr(10), GitGraphReferenceKind::Tag});
            } else if (raw.rfind("origin/", 0) == 0) {
                result.push_back({raw, GitGraphReferenceKind::Remote});
            } else if (raw.rfind("refs/remotes/", 0) == 0) {
                result.push_back({raw.substr(13), GitGraphReferenceKind::Remote});
            } else {
                result.push_back({raw, GitGraphReferenceKind::Branch});
            }
        }
        if (end == std::string_view::npos) break;
        start = end + 1;
    }
    return result;
}

} // namespace

GitGraphLayout layoutGitGraph(const std::vector<GitGraphCommit>& commits) {
    if (commits.empty()) return {};
    std::set<std::string> knownHashes;
    for (const auto& commit : commits) knownHashes.insert(commit.hash);
    std::vector<Lane> lanes;
    std::size_t nextColorIndex = 0;
    std::size_t maximumLaneCount = 0;
    GitGraphLayout result;
    result.rows.reserve(commits.size());

    for (const auto& commit : commits) {
        std::size_t currentLane = 0;
        auto existing = std::find_if(lanes.begin(), lanes.end(), [&](const Lane& lane) {
            return lane.hash == commit.hash;
        });
        if (existing != lanes.end()) {
            currentLane = static_cast<std::size_t>(existing - lanes.begin());
        } else {
            currentLane = lanes.size();
            lanes.push_back({commit.hash, nextColorIndex++});
        }

        std::vector<std::size_t> incomingColors;
        incomingColors.reserve(lanes.size());
        for (const auto& lane : lanes) incomingColors.push_back(lane.colorIndex);
        const auto currentColorIndex = lanes[currentLane].colorIndex;
        lanes.erase(lanes.begin() + static_cast<std::ptrdiff_t>(currentLane));

        for (std::size_t parentIndex = 0; parentIndex < commit.parentHashes.size(); ++parentIndex) {
            const auto& parentHash = commit.parentHashes[parentIndex];
            if (!knownHashes.contains(parentHash)) {
                result.hasMissingParents = true;
                continue;
            }
            const auto duplicate = std::find_if(lanes.begin(), lanes.end(), [&](const Lane& lane) {
                return lane.hash == parentHash;
            });
            if (duplicate != lanes.end()) continue;
            const auto insertionIndex = std::min(currentLane + parentIndex, lanes.size());
            const auto colorIndex = parentIndex == 0 ? currentColorIndex : nextColorIndex++;
            lanes.insert(lanes.begin() + static_cast<std::ptrdiff_t>(insertionIndex),
                         {parentHash, colorIndex});
        }

        std::vector<GitGraphEdge> parentEdges;
        parentEdges.reserve(commit.parentHashes.size());
        for (std::size_t parentIndex = 0; parentIndex < commit.parentHashes.size(); ++parentIndex) {
            const auto& parentHash = commit.parentHashes[parentIndex];
            auto target = std::find_if(lanes.begin(), lanes.end(), [&](const Lane& lane) {
                return lane.hash == parentHash;
            });
            const bool missing = target == lanes.end();
            if (missing) result.hasMissingParents = true;
            const auto targetLane = missing
                ? std::optional<std::size_t>{}
                : std::optional<std::size_t>(static_cast<std::size_t>(target - lanes.begin()));
            const auto colorIndex = targetLane
                ? lanes[*targetLane].colorIndex
                : (parentIndex == 0 ? currentColorIndex : nextColorIndex + parentIndex - 1);
            parentEdges.push_back({commit.hash + ":" + std::to_string(parentIndex) + ":" + parentHash,
                                   parentHash, targetLane, colorIndex, missing});
        }
        const auto laneCount = std::max({incomingColors.size(), lanes.size(), currentLane + 1,
                                         parentEdges.empty()
                                             ? std::size_t{0}
                                             : parentEdges.back().targetLane.value_or(0) + 1});
        maximumLaneCount = std::max(maximumLaneCount, laneCount);
        result.rows.push_back({commit, currentLane, laneCount, std::move(incomingColors),
                               std::move(parentEdges), labels(commit.decorations)});
    }
    result.laneCount = std::max<std::size_t>(1, maximumLaneCount);
    return result;
}

} // namespace lithe::windows::algorithms
