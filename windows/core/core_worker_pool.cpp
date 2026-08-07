#include "core_worker_pool.h"

#include <stdexcept>

namespace lithe::windows {

CoreWorkerPool::CoreWorkerPool(std::size_t workerCount) {
    if (workerCount == 0) workerCount = 1;
    workers_.reserve(workerCount);
    for (std::size_t index = 0; index < workerCount; ++index) {
        auto worker = std::make_unique<Worker>();
        worker->thread = std::thread([this, state = worker.get()] { run(*state); });
        workers_.push_back(std::move(worker));
    }
}

CoreWorkerPool::~CoreWorkerPool() {
    shutdown();
}

CoreCall CoreWorkerPool::makeCall(std::optional<std::uint64_t> timeoutMilliseconds) {
    return client_.makeCall(timeoutMilliseconds);
}

std::future<CoreResult<CoreResponse>> CoreWorkerPool::submit(
    const CoreCall& call,
    std::string command,
    std::string payloadJson) {
    auto task = std::make_shared<std::packaged_task<CoreResult<CoreResponse>()>>(
        [this, call, command = std::move(command), payloadJson = std::move(payloadJson)] {
            return client_.execute(call, command, payloadJson);
        });
    auto future = task->get_future();

    if (workers_.empty()) {
        throw std::runtime_error("Core worker pool has no workers");
    }
    const auto hash = std::hash<std::string>{}(call.operationID);
    auto& worker = *workers_[hash % workers_.size()];
    {
        std::lock_guard lifecycleLock(lifecycleMutex_);
        if (stopping_) throw std::runtime_error("Core worker pool is stopped");
        std::lock_guard workerLock(worker.mutex);
        if (worker.stopping) throw std::runtime_error("Core worker is stopped");
        worker.queue.emplace_back([task = std::move(task)]() mutable { (*task)(); });
    }
    worker.condition.notify_one();
    return future;
}

void CoreWorkerPool::submit(const CoreCall& call,
                            std::string command,
                            std::string payloadJson,
                            CompletionHandler completion) {
    if (!completion) throw std::invalid_argument("Core completion handler is empty");
    if (workers_.empty()) throw std::runtime_error("Core worker pool has no workers");

    auto task = [this, call, command = std::move(command), payloadJson = std::move(payloadJson),
                 completion = std::move(completion)]() mutable {
        completion(client_.execute(call, command, payloadJson));
    };
    const auto hash = std::hash<std::string>{}(call.operationID);
    auto& worker = *workers_[hash % workers_.size()];
    {
        std::lock_guard lifecycleLock(lifecycleMutex_);
        if (stopping_) throw std::runtime_error("Core worker pool is stopped");
        std::lock_guard workerLock(worker.mutex);
        if (worker.stopping) throw std::runtime_error("Core worker is stopped");
        worker.queue.emplace_back(std::move(task));
    }
    worker.condition.notify_one();
}

bool CoreWorkerPool::cancel(const CoreCall& call) const {
    return client_.cancel(call);
}

std::string CoreWorkerPool::version() const {
    return client_.version();
}

void CoreWorkerPool::shutdown() {
    {
        std::lock_guard lifecycleLock(lifecycleMutex_);
        if (stopping_) return;
        stopping_ = true;
    }
    for (const auto& worker : workers_) {
        {
            std::lock_guard lock(worker->mutex);
            worker->stopping = true;
        }
        worker->condition.notify_one();
    }
    for (const auto& worker : workers_) {
        if (worker->thread.joinable()) worker->thread.join();
    }
}

void CoreWorkerPool::run(Worker& worker) {
    for (;;) {
        std::function<void()> task;
        {
            std::unique_lock lock(worker.mutex);
            worker.condition.wait(lock, [&worker] {
                return worker.stopping || !worker.queue.empty();
            });
            if (worker.queue.empty()) {
                if (worker.stopping) return;
                continue;
            }
            task = std::move(worker.queue.front());
            worker.queue.pop_front();
        }
        task();
    }
}

} // namespace lithe::windows
