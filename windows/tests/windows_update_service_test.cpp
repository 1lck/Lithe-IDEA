#include "windows_update_service.h"

#include <cassert>
#include <map>
#include <string>
#include <vector>

namespace {

using namespace lithe::windows;
using namespace lithe::windows::app;

class FakeStorage final : public FileStorage {
public:
    std::string writtenPath;
    std::vector<std::uint8_t> written;

    std::string homeDirectory() const override { return "/tmp"; }
    std::string cacheDirectory() const override { return "/tmp"; }
    std::string applicationSupportDirectory() const override { return "/tmp"; }
    std::optional<FileMetadata> metadata(const std::string&) const override { return std::nullopt; }
    bool fileExists(const std::string&) const override { return false; }
    bool isExecutable(const std::string&) const override { return false; }
    std::vector<std::string> listDirectory(const std::string&) const override { return {}; }
    std::optional<std::vector<std::uint8_t>> readData(const std::string&, std::string&) const override {
        return std::nullopt;
    }
    bool writeData(const std::string& path, const std::vector<std::uint8_t>& data,
                   std::string&) override {
        writtenPath = path;
        written = data;
        return true;
    }
    bool createDirectory(const std::string&, bool, std::string&) override { return true; }
    bool removeItem(const std::string&, std::string&) override { return true; }
    bool moveItem(const std::string&, const std::string&, std::string&) override { return true; }
};

class FakeTransport final : public AIHTTPTransport {
public:
    std::map<std::string, std::string> bodies;
    std::vector<HTTPRequest> requests;

    std::optional<HTTPResponse> send(const HTTPRequest& request, std::string&) override {
        requests.push_back(request);
        const auto found = bodies.find(request.url);
        if (found == bodies.end()) return std::nullopt;
        return HTTPResponse{200, found->second};
    }
};

} // namespace

int main() {
    using namespace lithe::windows::app;
    const auto installerHash = WindowsUpdateService::sha256("installer-bytes");
    const std::string release = R"({
        "tag_name":"v0.2.0",
        "html_url":"https://github.com/example/lithe/releases/tag/v0.2.0",
        "draft":false,
        "prerelease":false,
        "assets":[
          {"name":"Lithe-0.2.0-windows-x64.msi","browser_download_url":"https://dl/lithe.msi","size":15},
          {"name":"SHA256SUMS.txt","browser_download_url":"https://dl/checksums.txt","size":80}
        ]
    })";
    WindowsUpdateError error;
    const auto parsed = WindowsUpdateService::parseRelease(release, error);
    assert(parsed && parsed->version == "0.2.0" && parsed->assets.size() == 2);
    assert(WindowsUpdateService::sha256("") ==
           "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    assert(WindowsUpdateService::checksumForAsset(
               installerHash + "  Lithe-0.2.0-windows-x64.msi\n", "Lithe-0.2.0-windows-x64.msi") ==
           installerHash);
    assert(WindowsUpdateService::checksumForAsset(
               "SHA256 (Lithe-0.2.0-windows-x64.msi) = " + installerHash + "\r\n",
               "Lithe-0.2.0-windows-x64.msi") == installerHash);

    FakeTransport transport;
    FakeStorage storage;
    transport.bodies["https://api.github.com/repos/example/lithe/releases/latest"] = release;
    transport.bodies["https://dl/checksums.txt"] =
        installerHash + "  Lithe-0.2.0-windows-x64.msi\n";
    transport.bodies["https://dl/lithe.msi"] = "installer-bytes";
    WindowsUpdateService service(transport, storage);
    const auto latest = service.checkLatest("example/lithe", "0.1.0", error);
    assert(latest && latest->version == "0.2.0");
    const auto asset = service.selectAsset(*latest, "x64", error);
    assert(asset && asset->sha256 == installerHash);
    assert(service.downloadAndVerify(*asset, "/tmp/Lithe-0.2.0.msi", error));
    assert(storage.writtenPath == "/tmp/Lithe-0.2.0.msi");
    assert(std::string(storage.written.begin(), storage.written.end()) == "installer-bytes");

    auto bad = *asset;
    bad.sha256 = std::string(64, '0');
    assert(!service.downloadAndVerify(bad, "/tmp/bad.msi", error));
    assert(error.code == WindowsUpdateErrorCode::ChecksumMismatch);
    return 0;
}
