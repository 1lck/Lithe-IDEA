#pragma once

#include "core_client.h"

#include <condition_variable>
#include <cstddef>
#include <deque>
#include <future>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace lithe::windows {

// A fixed, non-migrating executor for Rust core calls. The cancellation scope
// in lithe-core is thread-local, so a call must stay on one worker from entry
// through response. This class deliberately does not use QtConcurrent or
// std::async.
class CoreWorkerPool final {
public:
    using CompletionHandler = std::function<void(CoreResult<CoreResponse>)>;

    explicit CoreWorkerPool(std::size_t workerCount = 4);
    ~CoreWorkerPool();

    CoreWorkerPool(const CoreWorkerPool&) = delete;
    CoreWorkerPool& operator=(const CoreWorkerPool&) = delete;

    CoreCall makeCall(std::optional<std::uint64_t> timeoutMilliseconds = std::nullopt);
    std::future<CoreResult<CoreResponse>> submit(const CoreCall& call,
                                                 std::string command,
                                                 std::string payloadJson = "{}");
    void submit(const CoreCall& call,
                std::string command,
                std::string payloadJson,
                CompletionHandler completion);
    bool cancel(const CoreCall& call) const;
    std::string version() const;
    void shutdown();

private:
    struct Worker {
        std::mutex mutex;
        std::condition_variable condition;
        std::deque<std::function<void()>> queue;
        bool stopping = false;
        std::thread thread;
    };

    void run(Worker& worker);

    CoreClient client_;
    std::vector<std::unique_ptr<Worker>> workers_;
    mutable std::mutex lifecycleMutex_;
    bool stopping_ = false;
};

} // namespace lithe::windows
