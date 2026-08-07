#pragma once

#include <cstddef>
#include <optional>
#include <string>
#include <vector>

namespace lithe::windows::algorithms {

struct GitGraphCommit {
    std::string hash;
    std::vector<std::string> parentHashes;
    std::string decorations;
    std::string subject;
};

enum class GitGraphReferenceKind {
    Head,
    Branch,
    Remote,
    Tag,
};

struct GitGraphLabel {
    std::string title;
    GitGraphReferenceKind kind = GitGraphReferenceKind::Branch;
};

struct GitGraphEdge {
    std::string id;
    std::string parentHash;
    std::optional<std::size_t> targetLane;
    std::size_t colorIndex = 0;
    bool isMissing = false;
};

struct GitGraphRow {
    GitGraphCommit commit;
    std::size_t lane = 0;
    std::size_t laneCount = 0;
    std::vector<std::size_t> incomingLaneColors;
    std::vector<GitGraphEdge> parentEdges;
    std::vector<GitGraphLabel> labels;
};

struct GitGraphLayout {
    std::vector<GitGraphRow> rows;
    std::size_t laneCount = 0;
    bool hasMissingParents = false;
};

GitGraphLayout layoutGitGraph(const std::vector<GitGraphCommit>& commits);

} // namespace lithe::windows::algorithms
