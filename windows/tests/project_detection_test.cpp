#include "project_detection_service.h"

#include <cassert>
#include <algorithm>
#include <filesystem>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace {

std::string pathText(const std::filesystem::path& path) {
    const auto value = path.generic_u8string();
    return {reinterpret_cast<const char*>(value.data()), value.size()};
}

class FakeFileStorage final : public lithe::windows::FileStorage {
public:
    std::map<std::string, std::vector<std::string>> children;
    std::map<std::string, std::vector<std::uint8_t>> files;

    std::string homeDirectory() const override { return {}; }
    std::string cacheDirectory() const override { return {}; }
    std::string applicationSupportDirectory() const override { return {}; }

    std::optional<lithe::windows::FileMetadata> metadata(
        const std::string& path) const override {
        if (files.contains(path)) return lithe::windows::FileMetadata{0, std::nullopt, true, false};
        if (children.contains(path)) return lithe::windows::FileMetadata{
            std::nullopt, std::nullopt, false, true};
        return std::nullopt;
    }

    bool fileExists(const std::string& path) const override { return metadata(path).has_value(); }
    bool isExecutable(const std::string&) const override { return false; }

    std::vector<std::string> listDirectory(const std::string& path) const override {
        const auto found = children.find(path);
        return found == children.end() ? std::vector<std::string>{} : found->second;
    }

    std::optional<std::vector<std::uint8_t>> readData(
        const std::string& path, std::string&) const override {
        const auto found = files.find(path);
        return found == files.end() ? std::nullopt : std::optional(found->second);
    }

    bool writeData(const std::string&, const std::vector<std::uint8_t>&,
                   std::string&) override { return false; }
    bool createDirectory(const std::string&, bool, std::string&) override { return false; }
    bool removeItem(const std::string&, std::string&) override { return false; }
    bool moveItem(const std::string&, const std::string&, std::string&) override { return false; }

    void addDirectory(const std::filesystem::path& path) {
        const auto value = pathText(path);
        children.try_emplace(value);
        const auto parent = path.parent_path();
        if (parent == path || parent.empty()) return;
        addDirectory(parent);
        auto& entries = children[pathText(parent)];
        if (std::find(entries.begin(), entries.end(), value) == entries.end()) {
            entries.push_back(value);
        }
    }

    void addFile(const std::filesystem::path& path, std::string text = {}) {
        const auto value = pathText(path);
        addDirectory(path.parent_path());
        children[pathText(path.parent_path())].push_back(value);
        files[value] = std::vector<std::uint8_t>(text.begin(), text.end());
    }
};

}

int main() {
    FakeFileStorage storage;
    const std::filesystem::path root = "C:/workspace";
    storage.addDirectory(root);
    storage.addFile(root / "pom.xml", "<project><modules><module>module-a</module></modules></project>");
    storage.addFile(root / "mvnw.cmd");
    storage.addFile(root / "settings.gradle");
    storage.addFile(root / "gradlew.bat");
    storage.addFile(root / "src/main/java/App.java", "class App {}");
    storage.addDirectory(root / "module-a");
    storage.addFile(root / "module-a/pom.xml");
    storage.addFile(root / ".project");

    lithe::windows::app::ProjectDetectionService service(storage);
    const auto result = service.detect(root);
    assert(result.workspaceRoot == pathText(root));
    assert(result.candidates.size() == 1);
    const auto& candidate = result.candidates.front();
    assert(candidate.kind == lithe::windows::app::ProjectKind::Mixed);
    assert(candidate.hasMavenWrapper);
    assert(candidate.hasGradleWrapper);
    assert(candidate.hasGradleDescriptor);
    assert(candidate.javaSourceRoots == std::vector<std::string>{"src/main/java"});
    assert(candidate.modules.size() == 1);
    assert(candidate.modules.front().relativePath == "module-a");
    assert(candidate.modules.front().kind == lithe::windows::app::ProjectKind::Maven);
    assert(!candidate.evidence.empty());

    FakeFileStorage genericStorage;
    genericStorage.addDirectory(root);
    genericStorage.addFile(root / "README.md", "text");
    const auto generic = lithe::windows::app::ProjectDetectionService(genericStorage).detect(root);
    assert(generic.candidates.size() == 1);
    assert(generic.candidates.front().kind == lithe::windows::app::ProjectKind::Unknown);

    const auto detectKind = [](FakeFileStorage& value,
                               const std::filesystem::path& directory) {
        return lithe::windows::app::ProjectDetectionService(value)
            .detect(directory).candidates.front().kind;
    };

    FakeFileStorage mavenStorage;
    mavenStorage.addDirectory(root);
    mavenStorage.addFile(root / "pom.xml");
    mavenStorage.addFile(root / "mvnw.cmd");
    assert(detectKind(mavenStorage, root) == lithe::windows::app::ProjectKind::Maven);

    FakeFileStorage gradleStorage;
    gradleStorage.addDirectory(root);
    gradleStorage.addFile(root / "settings.gradle.kts");
    gradleStorage.addFile(root / "gradlew.bat");
    assert(detectKind(gradleStorage, root) == lithe::windows::app::ProjectKind::Gradle);

    FakeFileStorage eclipseStorage;
    eclipseStorage.addDirectory(root);
    eclipseStorage.addFile(root / ".project");
    eclipseStorage.addFile(root / ".classpath");
    eclipseStorage.addDirectory(root / ".settings");
    assert(detectKind(eclipseStorage, root) == lithe::windows::app::ProjectKind::Eclipse);

    FakeFileStorage intellijStorage;
    intellijStorage.addDirectory(root);
    intellijStorage.addDirectory(root / ".idea");
    intellijStorage.addFile(root / "app.iml");
    assert(detectKind(intellijStorage, root) == lithe::windows::app::ProjectKind::IntelliJ);

    FakeFileStorage intellijModuleStorage;
    intellijModuleStorage.addDirectory(root);
    intellijModuleStorage.addFile(root / "standalone.iml");
    assert(detectKind(intellijModuleStorage, root) == lithe::windows::app::ProjectKind::IntelliJ);

    FakeFileStorage javaStorage;
    javaStorage.addDirectory(root);
    javaStorage.addFile(root / "src/Main.java", "class Main {}");
    const auto javaResult = lithe::windows::app::ProjectDetectionService(javaStorage).detect(root);
    assert(javaResult.candidates.front().kind == lithe::windows::app::ProjectKind::PlainJava);
    assert(javaResult.candidates.front().javaSourceRoots == std::vector<std::string>{"src"});
    return 0;
}
