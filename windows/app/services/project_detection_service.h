#pragma once

#include "ports.h"

#include <filesystem>
#include <string>
#include <vector>

namespace lithe::windows::app {

enum class ProjectKind {
    Maven,
    Gradle,
    Eclipse,
    IntelliJ,
    PlainJava,
    Mixed,
    Unknown,
};

struct ProjectEvidence {
    std::string relativePath;
    std::string detail;
};

struct ProjectModule {
    std::string relativePath;
    ProjectKind kind = ProjectKind::Unknown;
    std::vector<ProjectEvidence> evidence;
};

struct ProjectCandidate {
    std::string root;
    ProjectKind kind = ProjectKind::Unknown;
    int confidence = 0;
    std::vector<ProjectEvidence> evidence;
    std::vector<ProjectModule> modules;
    std::vector<std::string> javaSourceRoots;
    bool hasMavenWrapper = false;
    bool hasGradleWrapper = false;
    bool hasMavenDescriptor = false;
    bool hasGradleDescriptor = false;
    bool hasJavaSources = false;
};

struct ProjectDetectionResult {
    std::string workspaceRoot;
    std::vector<ProjectCandidate> candidates;
};

class ProjectDetectionService final {
public:
    explicit ProjectDetectionService(FileStorage& storage);

    ProjectDetectionResult detect(const std::filesystem::path& workspaceRoot) const;

private:
    FileStorage& storage_;

    ProjectCandidate detectCandidate(const std::filesystem::path& root,
                                     const std::filesystem::path& workspaceRoot,
                                     bool includeJavaScan) const;
    void collectJavaFiles(const std::filesystem::path& root,
                          const std::filesystem::path& workspaceRoot,
                          std::vector<std::string>& sourceRoots,
                          bool& hasJavaSources) const;
};

}
