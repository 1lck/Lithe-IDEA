#include "project_detection_service.h"

#include <algorithm>
#include <set>

namespace lithe::windows::app {
namespace {

std::string pathText(const std::filesystem::path& path) {
    const auto value = path.generic_u8string();
    return {reinterpret_cast<const char*>(value.data()), value.size()};
}

std::filesystem::path pathFromText(const std::string& path) {
    const auto* data = reinterpret_cast<const char8_t*>(path.data());
    return std::filesystem::path(std::u8string(data, data + path.size()));
}

std::string relativeText(const std::filesystem::path& root,
                         const std::filesystem::path& path) {
    return pathText(path.lexically_relative(root));
}

bool isFile(const FileStorage& storage, const std::filesystem::path& path) {
    const auto value = storage.metadata(pathText(path));
    return value && value->isRegularFile;
}

bool isDirectory(const FileStorage& storage, const std::filesystem::path& path) {
    const auto value = storage.metadata(pathText(path));
    return value && value->isDirectory;
}

bool hasAnyFile(const FileStorage& storage,
               const std::filesystem::path& root,
               std::initializer_list<const char*> names) {
    return std::any_of(names.begin(), names.end(), [&](const char* name) {
        return isFile(storage, root / name);
    });
}

void addEvidence(ProjectCandidate& candidate,
                 const std::filesystem::path& workspaceRoot,
                 const std::filesystem::path& path,
                 const char* detail) {
    candidate.evidence.push_back({relativeText(workspaceRoot, path), detail});
}

void addSourceRoot(std::vector<std::string>& roots, const std::string& value) {
    if (value.empty() || std::find(roots.begin(), roots.end(), value) != roots.end()) return;
    roots.push_back(value);
    std::sort(roots.begin(), roots.end());
}

ProjectKind singleKind(const std::set<ProjectKind>& kinds, bool hasJavaSources) {
    if (kinds.size() > 1) return ProjectKind::Mixed;
    if (!kinds.empty()) return *kinds.begin();
    return hasJavaSources ? ProjectKind::PlainJava : ProjectKind::Unknown;
}

int confidence(ProjectKind kind) {
    switch (kind) {
    case ProjectKind::Mixed: return 100;
    case ProjectKind::Maven: return 95;
    case ProjectKind::Gradle: return 90;
    case ProjectKind::Eclipse: return 85;
    case ProjectKind::IntelliJ: return 80;
    case ProjectKind::PlainJava: return 60;
    case ProjectKind::Unknown: return 0;
    }
    return 0;
}

}

ProjectDetectionService::ProjectDetectionService(FileStorage& storage)
    : storage_(storage) {}

ProjectDetectionResult ProjectDetectionService::detect(
    const std::filesystem::path& workspaceRoot) const {
    ProjectDetectionResult result;
    const auto normalizedRoot = workspaceRoot.lexically_normal();
    result.workspaceRoot = pathText(normalizedRoot);
    if (!isDirectory(storage_, normalizedRoot)) return result;

    auto candidate = detectCandidate(normalizedRoot, normalizedRoot, true);
    const auto children = storage_.listDirectory(pathText(normalizedRoot));
    for (const auto& childText : children) {
        const auto child = pathFromText(childText);
        if (!isDirectory(storage_, child)) continue;
        const auto nested = detectCandidate(child, normalizedRoot, false);
        if (nested.kind == ProjectKind::Unknown) continue;
        candidate.modules.push_back({relativeText(normalizedRoot, child), nested.kind,
                                     std::move(nested.evidence)});
    }
    std::sort(candidate.modules.begin(), candidate.modules.end(),
              [](const ProjectModule& left, const ProjectModule& right) {
                  return left.relativePath < right.relativePath;
              });
    result.candidates.push_back(std::move(candidate));
    return result;
}

ProjectCandidate ProjectDetectionService::detectCandidate(
    const std::filesystem::path& root,
    const std::filesystem::path& workspaceRoot,
    bool includeJavaScan) const {
    ProjectCandidate candidate;
    candidate.root = pathText(root);
    std::set<ProjectKind> kinds;

    candidate.hasMavenDescriptor = isFile(storage_, root / "pom.xml");
    if (candidate.hasMavenDescriptor) {
        kinds.insert(ProjectKind::Maven);
        addEvidence(candidate, workspaceRoot, root / "pom.xml", "Maven descriptor");
    }
    candidate.hasMavenWrapper = hasAnyFile(storage_, root, {"mvnw", "mvnw.cmd"});
    if (candidate.hasMavenWrapper) {
        kinds.insert(ProjectKind::Maven);
        const auto wrapper = isFile(storage_, root / "mvnw.cmd") ? root / "mvnw.cmd" : root / "mvnw";
        addEvidence(candidate, workspaceRoot, wrapper, "Maven wrapper");
    }

    candidate.hasGradleDescriptor = hasAnyFile(storage_, root,
                                                {"settings.gradle", "settings.gradle.kts",
                                                 "build.gradle", "build.gradle.kts"});
    if (candidate.hasGradleDescriptor) {
        kinds.insert(ProjectKind::Gradle);
        for (const auto* name : {"settings.gradle", "settings.gradle.kts",
                                 "build.gradle", "build.gradle.kts"}) {
            if (isFile(storage_, root / name)) {
                addEvidence(candidate, workspaceRoot, root / name, "Gradle descriptor");
            }
        }
    }
    candidate.hasGradleWrapper = hasAnyFile(storage_, root, {"gradlew", "gradlew.bat"});
    if (candidate.hasGradleWrapper) {
        kinds.insert(ProjectKind::Gradle);
        const auto wrapper = isFile(storage_, root / "gradlew.bat") ? root / "gradlew.bat" : root / "gradlew";
        addEvidence(candidate, workspaceRoot, wrapper, "Gradle wrapper");
    }

    if (hasAnyFile(storage_, root, {".project", ".classpath"}) ||
        isDirectory(storage_, root / ".settings")) {
        kinds.insert(ProjectKind::Eclipse);
        for (const auto* name : {".project", ".classpath"}) {
            if (isFile(storage_, root / name)) {
                addEvidence(candidate, workspaceRoot, root / name, "Eclipse metadata");
            }
        }
        if (isDirectory(storage_, root / ".settings")) {
            addEvidence(candidate, workspaceRoot, root / ".settings", "Eclipse settings");
        }
    }

    const auto rootChildren = storage_.listDirectory(pathText(root));
    const bool hasIntelliJModule = std::any_of(rootChildren.begin(), rootChildren.end(), [&](const auto& childText) {
        const auto child = pathFromText(childText);
        return isFile(storage_, child) && child.extension() == ".iml";
    });
    if (isDirectory(storage_, root / ".idea") || hasIntelliJModule) {
        kinds.insert(ProjectKind::IntelliJ);
        if (isDirectory(storage_, root / ".idea")) {
            addEvidence(candidate, workspaceRoot, root / ".idea", "IntelliJ metadata");
        }
        for (const auto& childText : rootChildren) {
            const auto child = pathFromText(childText);
            if (child.extension() == ".iml" && isFile(storage_, child)) {
                addEvidence(candidate, workspaceRoot, child, "IntelliJ module file");
            }
        }
    }

    if (includeJavaScan) collectJavaFiles(root, workspaceRoot,
                                           candidate.javaSourceRoots,
                                           candidate.hasJavaSources);
    if (candidate.hasJavaSources && kinds.empty()) {
        addEvidence(candidate, workspaceRoot, root, "Java source files");
    }
    candidate.kind = singleKind(kinds, candidate.hasJavaSources);
    candidate.confidence = confidence(candidate.kind);
    return candidate;
}

void ProjectDetectionService::collectJavaFiles(
    const std::filesystem::path& root,
    const std::filesystem::path& workspaceRoot,
    std::vector<std::string>& sourceRoots,
    bool& hasJavaSources) const {
    std::vector<std::pair<std::filesystem::path, int>> pending{{root, 0}};
    std::size_t visitedFiles = 0;
    const std::set<std::string> ignored = {".git", ".gradle", "build", "target", "out"};
    while (!pending.empty() && visitedFiles < 2048) {
        const auto [current, depth] = pending.back();
        pending.pop_back();
        for (const auto& childText : storage_.listDirectory(pathText(current))) {
            const auto child = pathFromText(childText);
            if (isDirectory(storage_, child)) {
                if (depth < 5 && !ignored.contains(child.filename().string())) {
                    pending.push_back({child, depth + 1});
                }
                continue;
            }
            if (!isFile(storage_, child)) continue;
            ++visitedFiles;
            if (child.extension() != ".java") continue;
            hasJavaSources = true;
            const auto relative = relativeText(workspaceRoot, child);
            const char* bestMarker = nullptr;
            std::size_t bestLength = 0;
            for (const auto* marker : {"src/main/java", "src/test/java", "src"}) {
                const std::string prefix = std::string(marker) + "/";
                if (relative.rfind(prefix, 0) == 0 && prefix.size() > bestLength) {
                    bestMarker = marker;
                    bestLength = prefix.size();
                }
            }
            if (bestMarker != nullptr) addSourceRoot(sourceRoots, bestMarker);
        }
    }
    if (sourceRoots.empty() && hasJavaSources) addSourceRoot(sourceRoots, ".");
}

}
