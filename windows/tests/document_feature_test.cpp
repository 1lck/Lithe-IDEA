#include "document_feature.h"

#include <cassert>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <string>
#include <utility>

using namespace lithe::windows;
using namespace lithe::windows::app;

extern "C" {

const char* lithe_core_version(void) {
    return "document-feature-test";
}

char* lithe_core_execute_json(const char*) {
    const char* response = "{\"id\":null,\"ok\":false,\"error\":{\"code\":\"unknown\",\"message\":\"unused\"}}";
    auto* copy = static_cast<char*>(std::malloc(std::strlen(response) + 1));
    std::memcpy(copy, response, std::strlen(response) + 1);
    return copy;
}

std::int32_t lithe_core_cancel(const char*) {
    return 0;
}

void lithe_core_free_string(char* value) {
    std::free(value);
}

}

namespace {

WorkspaceOperationResult result(std::string json, bool stale = false) {
    WorkspaceOperationResult value;
    value.response.json = std::move(json);
    value.envelope = decodeCoreEnvelope(value.response);
    value.stale = stale;
    return value;
}

std::string readResponse(const std::string& path, const std::string& text,
                         const std::string& version) {
    return "{\"id\":\"read\",\"ok\":true,\"data\":{\"path\":\"" + path +
        "\",\"text\":\"" + text + "\",\"version\":\"" + version +
        "\",\"lineEnding\":\"lf\",\"hasUtf8Bom\":false}}";
}

std::string writeResponse(const std::string& path, const std::string& version) {
    return "{\"id\":\"write\",\"ok\":true,\"data\":{\"path\":\"" + path +
        "\",\"bytesWritten\":1,\"newVersion\":\"" + version + "\"}}";
}

class FakeDocumentOperations final : public DocumentOperations {
public:
    struct PendingRead {
        std::string path;
        Handler handler;
    };
    struct PendingWrite {
        FileWriteRequestDto request;
        Handler handler;
    };

    void read(std::string relativePath, Handler handler) override {
        reads.push_back({std::move(relativePath), std::move(handler)});
    }

    void write(FileWriteRequestDto request, Handler handler) override {
        writes.push_back({std::move(request), std::move(handler)});
    }

    std::deque<PendingRead> reads;
    std::deque<PendingWrite> writes;
};

} // namespace

int main() {
    FakeDocumentOperations operations;
    DocumentFeatureModel model(operations);

    model.open("src/A.txt");
    model.open("src/B.txt");
    assert(operations.reads.size() == 2);
    auto secondRead = std::move(operations.reads[1].handler);
    operations.reads.pop_back();
    secondRead(result(readResponse("src/B.txt", "bravo", "sha256:b")));
    auto firstRead = std::move(operations.reads.front().handler);
    operations.reads.pop_front();
    firstRead(result(readResponse("src/A.txt", "alpha", "sha256:a")));

    assert(model.openPaths() == std::vector<std::string>({"src/A.txt", "src/B.txt"}));
    assert(model.state("src/A.txt")->text == "alpha");
    assert(model.state("SRC\\B.TXT")->text == "bravo");
    assert(model.state().relativePath == "src/B.txt");

    model.setText("changed");
    assert(model.state().isDirty);
    model.setText("bravo");
    assert(!model.state().isDirty);
    model.setText("first edit");

    int saveCallbacks = 0;
    model.save([&](DocumentFeatureState state) {
        ++saveCallbacks;
        assert(!state.isSaving);
    });
    assert(operations.writes.size() == 1);
    assert(operations.writes.front().request.expectedVersion == "sha256:b");
    assert(operations.writes.front().request.text == "first edit");

    model.setText("second edit");
    model.save([&](DocumentFeatureState) { ++saveCallbacks; });
    assert(operations.writes.size() == 1);
    auto firstWrite = std::move(operations.writes.front().handler);
    operations.writes.pop_front();
    firstWrite(result(writeResponse("src/B.txt", "sha256:b2")));
    assert(operations.writes.size() == 1);
    assert(operations.writes.front().request.text == "second edit");
    assert(operations.writes.front().request.expectedVersion == "sha256:b2");
    assert(model.state().isSaving && model.state().isDirty);

    auto secondWrite = std::move(operations.writes.front().handler);
    operations.writes.pop_front();
    secondWrite(result(writeResponse("src/B.txt", "sha256:b3")));
    assert(!model.state().isSaving && !model.state().isDirty);
    assert(saveCallbacks == 2);

    model.setText("dirty again");
    model.externalModified("src/B.txt");
    assert(operations.reads.size() == 1);
    auto externalRead = std::move(operations.reads.front().handler);
    operations.reads.pop_front();
    externalRead(result(readResponse("src/B.txt", "disk edit", "sha256:external")));
    assert(model.state().text == "dirty again");
    assert(model.state().externalState == DocumentExternalState::Modified);
    assert(model.keepEditorVersion("src/B.txt"));
    assert(model.state().isDirty && model.state().diskVersion == "sha256:external");

    const auto snapshot = model.documentSafetySnapshot();
    assert(snapshot.dirtyPaths == std::vector<std::string>({"src/B.txt"}));
    assert(!model.close("src/B.txt"));
    assert(model.close("src/B.txt", true));
    assert(model.state().relativePath == "src/A.txt");

    model.externalDeleted("src/A.txt");
    assert(model.state().externalState == DocumentExternalState::Deleted);
    model.save();
    assert(operations.writes.size() == 1 && operations.writes.front().request.createOnly);
    auto recreateWrite = std::move(operations.writes.front().handler);
    operations.writes.pop_front();
    recreateWrite(result(writeResponse("src/A.txt", "sha256:a2")));
    assert(model.state().externalState == DocumentExternalState::None);

    model.open("src/C.txt");
    assert(operations.reads.size() == 1);
    auto staleRead = std::move(operations.reads.front().handler);
    operations.reads.pop_front();
    model.resetForWorkspace();
    staleRead(result(readResponse("src/C.txt", "stale", "sha256:c")));
    assert(model.openPaths().empty());

    FakeDocumentOperations destructionOperations;
    auto destroyedModel = std::make_unique<DocumentFeatureModel>(destructionOperations);
    destroyedModel->open("src/late.txt");
    auto lateRead = std::move(destructionOperations.reads.front().handler);
    destructionOperations.reads.pop_front();
    destroyedModel.reset();
    lateRead(result(readResponse("src/late.txt", "ignored", "sha256:late")));
    return 0;
}
