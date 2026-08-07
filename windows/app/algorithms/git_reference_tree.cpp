#include "git_reference_tree.h"

#include <algorithm>
#include <cctype>
#include <map>
#include <string_view>

namespace lithe::windows::algorithms {
namespace {

struct MutableNode {
    std::string name;
    std::string path;
    std::optional<GitReferenceInfo> reference;
    std::map<std::string, MutableNode> children;
};

std::vector<std::string> components(std::string_view value) {
    std::vector<std::string> result;
    std::size_t start = 0;
    while (start <= value.size()) {
        const auto end = value.find('/', start);
        const auto partEnd = end == std::string_view::npos ? value.size() : end;
        if (partEnd > start) result.emplace_back(value.substr(start, partEnd - start));
        if (end == std::string_view::npos) break;
        start = end + 1;
    }
    return result;
}

bool naturalLess(std::string_view left, std::string_view right) {
    std::size_t leftIndex = 0;
    std::size_t rightIndex = 0;
    while (leftIndex < left.size() && rightIndex < right.size()) {
        const auto leftDigit = std::isdigit(static_cast<unsigned char>(left[leftIndex])) != 0;
        const auto rightDigit = std::isdigit(static_cast<unsigned char>(right[rightIndex])) != 0;
        if (leftDigit && rightDigit) {
            const auto leftStart = leftIndex;
            const auto rightStart = rightIndex;
            while (leftIndex < left.size() &&
                   std::isdigit(static_cast<unsigned char>(left[leftIndex]))) ++leftIndex;
            while (rightIndex < right.size() &&
                   std::isdigit(static_cast<unsigned char>(right[rightIndex]))) ++rightIndex;
            const auto leftDigits = left.substr(leftStart, leftIndex - leftStart);
            const auto rightDigits = right.substr(rightStart, rightIndex - rightStart);
            const auto leftTrimStart = leftDigits.find_first_not_of('0');
            const auto rightTrimStart = rightDigits.find_first_not_of('0');
            const auto leftNormalized = leftTrimStart == std::string_view::npos
                ? std::string_view("0") : leftDigits.substr(leftTrimStart);
            const auto rightNormalized = rightTrimStart == std::string_view::npos
                ? std::string_view("0") : rightDigits.substr(rightTrimStart);
            if (leftNormalized.size() != rightNormalized.size()) {
                return leftNormalized.size() < rightNormalized.size();
            }
            if (leftNormalized != rightNormalized) return leftNormalized < rightNormalized;
            if (leftDigits.size() != rightDigits.size()) {
                return leftDigits.size() < rightDigits.size();
            }
            continue;
        }
        const auto leftCharacter = static_cast<unsigned char>(left[leftIndex]);
        const auto rightCharacter = static_cast<unsigned char>(right[rightIndex]);
        const auto leftLower = static_cast<char>(std::tolower(leftCharacter));
        const auto rightLower = static_cast<char>(std::tolower(rightCharacter));
        if (leftLower != rightLower) return leftLower < rightLower;
        ++leftIndex;
        ++rightIndex;
    }
    if (leftIndex != left.size() || rightIndex != right.size()) {
        return leftIndex == left.size();
    }
    return left < right;
}

std::vector<GitReferenceTreeNode> makeNodes(const MutableNode& node) {
    std::vector<const MutableNode*> children;
    children.reserve(node.children.size());
    for (const auto& [_, child] : node.children) children.push_back(&child);
    std::sort(children.begin(), children.end(), [](const auto* left, const auto* right) {
        if (left->reference.has_value() != right->reference.has_value()) {
            return left->reference.has_value();
        }
        return naturalLess(left->name, right->name);
    });

    std::vector<GitReferenceTreeNode> result;
    result.reserve(children.size());
    for (const auto* child : children) {
        result.push_back({child->path, child->name, child->reference, makeNodes(*child)});
    }
    return result;
}

} // namespace

std::vector<GitReferenceTreeNode> buildGitReferenceTree(
    const std::vector<GitReferenceInfo>& references) {
    MutableNode root;
    for (const auto& reference : references) {
        const auto parts = components(reference.shortName);
        if (parts.empty()) continue;
        MutableNode* node = &root;
        std::string path;
        for (const auto& part : parts) {
            if (!path.empty()) path += '/';
            path += part;
            auto [child, inserted] = node->children.try_emplace(part);
            if (inserted) {
                child->second.name = part;
                child->second.path = path;
            }
            node = &child->second;
        }
        node->reference = reference;
    }
    return makeNodes(root);
}

} // namespace lithe::windows::algorithms
