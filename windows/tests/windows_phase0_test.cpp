#include "core_client.h"
#include "core_worker_pool.h"
#include "win32_directory_watcher.h"
#include "win32_file_system.h"
#include "win32_file_storage.h"
#include "win32_key_value_store.h"
#include "win32_process_runner.h"

#include <algorithm>
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>
#include <variant>
#include <vector>

namespace {

std::mutex coreMutex;
std::string lastRequest;
std::unordered_map<std::string, std::thread::id> operationThreads;
std::vector<std::string> cancelledOperations;

std::string operationIDFromRequest(const char* request) {
    const std::string value(request == nullptr ? "" : request);
    const auto marker = std::string("\"operationId\":\"");
    const auto start = value.find(marker);
    if (start == std::string::npos) return {};
    const auto first = start + marker.size();
    const auto end = value.find('"', first);
    return end == std::string::npos ? std::string{} : value.substr(first, end - first);
}

} // namespace

extern "C" {

const char* lithe_core_version(void) {
    return "test-core";
}

char* lithe_core_execute_json(const char* request) {
    const auto operation = operationIDFromRequest(request);
    {
        std::lock_guard lock(coreMutex);
        lastRequest = request == nullptr ? "" : request;
        if (!operation.empty()) operationThreads[operation] = std::this_thread::get_id();
    }
    const std::string response =
        "{\"id\":\"test\",\"ok\":true,\"data\":{\"protocolVersion\":1}}";
    auto* result = static_cast<char*>(std::malloc(response.size() + 1));
    assert(result != nullptr);
    std::memcpy(result, response.c_str(), response.size() + 1);
    return result;
}

std::int32_t lithe_core_cancel(const char* operationID) {
    std::lock_guard lock(coreMutex);
    cancelledOperations.emplace_back(operationID == nullptr ? "" : operationID);
    return 1;
}

void lithe_core_free_string(char* value) {
    std::free(value);
}

} // extern "C"

namespace {

std::filesystem::path testRoot() {
    static std::atomic<unsigned> sequence{0};
    return std::filesystem::temp_directory_path() /
        ("lithe-windows-phase0-" +
         std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()) +
         "-" + std::to_string(sequence.fetch_add(1)));
}

void testCoreClientAndWorkerPool() {
    lithe::windows::CoreClient client;
    const auto call = client.makeCall(30000);
    assert(call.isValid());
    const auto response = client.execute(call, "core.ping");
    assert(response && response->isValid());
    const auto invalidResponse = client.execute(lithe::windows::CoreCall{}, "core.ping");
    assert(!invalidResponse &&
           invalidResponse.error().code == lithe::windows::CoreErrorCode::InvalidRequest);
    {
        std::lock_guard lock(coreMutex);
        assert(lastRequest.find("\"operationId\":\"" + call.operationID + "\"") !=
               std::string::npos);
        assert(lastRequest.find("\"timeoutMilliseconds\":30000") != std::string::npos);
    }
    assert(client.cancel(call));

    lithe::windows::CoreWorkerPool pool(4);
    const auto pooledCall = pool.makeCall();
    auto first = pool.submit(pooledCall, "core.ping");
    auto second = pool.submit(pooledCall, "core.ping");
    const auto firstResponse = first.get();
    const auto secondResponse = second.get();
    assert(firstResponse && firstResponse->isValid());
    assert(secondResponse && secondResponse->isValid());
    {
        std::lock_guard lock(coreMutex);
        assert(operationThreads.contains(pooledCall.operationID));
    }
    assert(pool.cancel(pooledCall));
    pool.shutdown();
}

void testFileSystem() {
    const auto root = testRoot();
    std::filesystem::create_directories(root);
    lithe::windows::Win32FileSystem files;
    std::string error;
    const auto textPath = root / "nested" / "text.txt";
    assert(files.writeAtomic(textPath.string(), "hello", error));
    const auto text = files.readUtf8(textPath.string());
    assert(text.succeeded && text.text == "hello");

    const auto bomPath = root / "bom.txt";
    {
        std::ofstream output(bomPath, std::ios::binary);
        output << "\xef\xbb\xbfhello";
    }
    const auto bom = files.readUtf8(bomPath.string());
    assert(bom.succeeded && bom.text == "hello");

    const auto utf16Path = root / "utf16.txt";
    {
        const std::string bytes = {
            static_cast<char>(0xff), static_cast<char>(0xfe),
            'h', 0, 'i', 0, ' ', 0,
            static_cast<char>(0x60), static_cast<char>(0x4f),
            static_cast<char>(0x7d), static_cast<char>(0x59)};
        std::ofstream output(utf16Path, std::ios::binary);
        output.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
    }
    const auto utf16 = files.readUtf8(utf16Path.string());
    assert(utf16.succeeded && utf16.text == "hi 你好");

    const auto invalidPath = root / "invalid.txt";
    {
        const std::string bytes = {static_cast<char>(0xc3), static_cast<char>(0x28)};
        std::ofstream output(invalidPath, std::ios::binary);
        output.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
    }
    assert(!files.readUtf8(invalidPath.string()).succeeded);

    const auto movedPath = root / "moved.txt";
    assert(files.move(textPath.string(), movedPath.string(), error));
    assert(files.remove(movedPath.string(), error));
    assert(files.remove((root / "nested").string(), error));
    std::filesystem::remove_all(root);
}

void testTypedKeyValueStore() {
    const auto root = testRoot();
    lithe::windows::Win32KeyValueStore store(root);
    std::string error;
    assert(store.writeValue("a/b", lithe::windows::KeyValueValue{true}, error));
    assert(store.writeValue("a\\b", lithe::windows::KeyValueValue{std::int64_t{42}}, error));
    assert(store.writeValue("a:b", lithe::windows::KeyValueValue{std::vector<std::string>{"one", "two"}}, error));
    assert(store.writeValue("bytes", lithe::windows::KeyValueValue{std::vector<std::uint8_t>{0, 1, 255}}, error));

    const auto first = store.readValue("a/b");
    const auto second = store.readValue("a\\b");
    const auto third = store.readValue("a:b");
    const auto bytes = store.readValue("bytes");
    assert(first && std::get<bool>(*first));
    assert(second && std::get<std::int64_t>(*second) == 42);
    assert(third && std::get<std::vector<std::string>>(*third).size() == 2);
    assert(bytes && std::get<std::vector<std::uint8_t>>(*bytes).back() == 255);
    assert(store.remove("a/b", error));
    std::filesystem::remove_all(root);
}

void testFileStoragePort() {
    const auto root = testRoot();
    lithe::windows::Win32FileStorage storage;
    std::string error;
    assert(storage.createDirectory(root.string(), true, error));
    const auto file = root / "data.bin";
    const std::vector<std::uint8_t> input{0, 1, 2, 255};
    assert(storage.writeData(file.string(), input, error));
    const auto output = storage.readData(file.string(), error);
    assert(output && *output == input);
    const auto metadata = storage.metadata(file.string());
    assert(metadata && metadata->isRegularFile && metadata->byteCount == input.size());
    assert(storage.fileExists(file.string()));
    assert(!storage.listDirectory(root.string()).empty());
    assert(storage.removeItem(file.string(), error));
    assert(storage.removeItem(root.string(), error));
}

#ifdef _WIN32

void testWindowsProcessRoundTrip() {
    const auto* shell = std::getenv("ComSpec");
    assert(shell != nullptr && *shell != '\0');
    lithe::windows::ProcessRequest request;
    request.executablePath = shell;
    request.arguments = {"/C", "more"};
    request.standardInput = "phase0-stdin\r\n";
    request.keepsStandardInputOpen = false;
    request.timeoutMilliseconds = 5000;
    const auto result = lithe::windows::Win32ProcessRunner().run(request);
    assert(result.started);
    assert(result.exitCode == 0);
    assert(result.output.find("phase0-stdin") != std::string::npos);
}

void testWindowsDirectoryWatcher() {
    const auto root = testRoot();
    std::filesystem::create_directories(root);
    lithe::windows::Win32DirectoryChangeSource watcher;
    std::mutex mutex;
    std::condition_variable condition;
    std::vector<lithe::windows::DirectoryChangeSource::Change> changes;
    std::string watcherError;
    watcher.start(
        root.string(),
        [&](const auto& batch) {
            std::lock_guard lock(mutex);
            changes.insert(changes.end(), batch.begin(), batch.end());
            condition.notify_one();
        },
        [&](const auto& error) {
            std::lock_guard lock(mutex);
            watcherError = error;
            condition.notify_one();
        });
    for (int index = 0; index < 20; ++index) {
        std::ofstream output(root / ("file-" + std::to_string(index) + ".txt"));
        output << index;
    }
    {
        std::unique_lock lock(mutex);
        condition.wait_for(lock, std::chrono::seconds(3), [&] {
            return !changes.empty() || !watcherError.empty();
        });
    }
    watcher.stop();
    assert(watcherError.empty());
    assert(!changes.empty());
    const auto hasAddedFile = std::any_of(changes.begin(), changes.end(), [](const auto& change) {
        return change.kind == lithe::windows::DirectoryChangeSource::ChangeKind::Added;
    });
    assert(hasAddedFile);
    for (const auto& change : changes) {
        assert(change.path.find('\\') == std::string::npos);
    }
    std::filesystem::remove_all(root);
}

#endif

} // namespace

int main() {
    testCoreClientAndWorkerPool();
    testFileSystem();
    testTypedKeyValueStore();
    testFileStoragePort();
#ifdef _WIN32
    testWindowsProcessRoundTrip();
    testWindowsDirectoryWatcher();
#endif
    return 0;
}
