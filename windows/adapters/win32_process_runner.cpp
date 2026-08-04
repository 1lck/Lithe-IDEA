#include "win32_process_runner.h"

#include "win32_process_session.h"

#include <condition_variable>
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
    condition.wait(lock, [&] { return completed; });
    return result;
}

} // namespace lithe::windows
