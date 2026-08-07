#include "win32_process_runner.h"

#include "win32_process_session.h"

#include <condition_variable>
#include <chrono>
#include <limits>
#include <mutex>

namespace lithe::windows {

ProcessResult Win32ProcessRunner::run(const ProcessRequest& request) {
    Win32ProcessSession session;
    std::mutex mutex;
    std::condition_variable condition;
    ProcessResult result;
    bool completed = false;
    session.setOutputHandler([&](const std::string& output) {
        std::lock_guard lock(mutex);
        result.output += output;
    });
    session.setErrorHandler([&](const std::string& error) {
        std::lock_guard lock(mutex);
        result.output += error;
    });
    session.setLifecycleHandler([&](const ProcessLifecycleEvent& event) {
        std::lock_guard lock(mutex);
        if (event.state == ProcessLifecycleState::Running) result.started = true;
        if (event.state == ProcessLifecycleState::Finished || event.state == ProcessLifecycleState::Failed) {
            result.exitCode = event.exitCode.value_or(1);
            if (!event.message.empty()) result.output += event.message;
            completed = true;
            condition.notify_one();
        }
    });
    session.start(request);
    std::unique_lock lock(mutex);
    std::chrono::milliseconds waitDuration = std::chrono::hours(24);
    if (request.timeoutMilliseconds) {
        constexpr auto maximum =
            std::numeric_limits<std::chrono::milliseconds::rep>::max();
        const auto timeout = *request.timeoutMilliseconds;
        waitDuration = timeout >= static_cast<std::uint64_t>(maximum) - 2000
            ? std::chrono::milliseconds::max()
            : std::chrono::milliseconds(static_cast<std::int64_t>(timeout + 2000));
    }
    if (!condition.wait_for(lock, waitDuration, [&] { return completed; })) {
        lock.unlock();
        session.stop();
        lock.lock();
        if (!completed) {
            result.exitCode = 124;
            result.output += "Process runner timed out";
            completed = true;
        }
    }
    return result;
}

} // namespace lithe::windows
