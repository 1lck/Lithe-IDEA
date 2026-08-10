#include "terminal_model.h"

#include <utility>

namespace lithe::windows::app {

TerminalModel::TerminalModel(TransportFactory factory)
    : factory_(std::move(factory)) {
}

TerminalModel::~TerminalModel() {
    shutdown();
}

std::string TerminalModel::allocateId() {
    return "t" + std::to_string(nextId_++);
}

std::string TerminalModel::create(const TerminalShellSpec& shell,
                                  const std::string& workingDirectory,
                                  const std::map<std::string, std::string>& environment) {
    std::string id;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        id = allocateId();
    }

    auto transport = factory_();
    if (!transport) return {};

    auto session = std::make_unique<TerminalSession>(id, std::move(transport));
    attachHandlers(*session);
    // The initial operationID is the session id; restart() derives a fresh one.
    session->launch(shell, workingDirectory, environment, id);

    {
        std::lock_guard<std::mutex> lock(mutex_);
        sessions_[id] = std::move(session);
        currentId_ = id;
    }
    notifyListChanged();
    return id;
}

bool TerminalModel::select(const std::string& id) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!sessions_.contains(id)) return false;
    if (currentId_ == id) return true;
    currentId_ = id;
    return true;
}

void TerminalModel::close(const std::string& id) {
    std::unique_ptr<TerminalSession> removed;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = sessions_.find(id);
        if (it == sessions_.end()) return;
        removed = std::move(it->second);
        sessions_.erase(it);
        if (currentId_ == id) {
            currentId_.clear();
            if (!sessions_.empty()) currentId_ = sessions_.begin()->first;
        }
    }
    // Drop the session outside the lock; its destructor stops the transport and
    // joins the worker thread before freeing any handler state.
    removed.reset();
    notifyListChanged();
}

void TerminalModel::closeAll() {
    // Bump the epoch first so any callback already in flight on a transport
    // worker thread is dropped before it can reach the (soon-removed) session.
    ++epoch_;

    std::map<std::string, std::unique_ptr<TerminalSession>> drained;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        drained = std::move(sessions_);
        currentId_.clear();
    }
    drained.clear();
    notifyListChanged();
}

void TerminalModel::shutdown() {
    ++epoch_;
    std::map<std::string, std::unique_ptr<TerminalSession>> drained;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        drained = std::move(sessions_);
        currentId_.clear();
    }
    drained.clear();
}

bool TerminalModel::send(const std::string& id, const std::string& input) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = sessions_.find(id);
    if (it == sessions_.end()) return false;
    it->second->send(input);
    return true;
}

bool TerminalModel::interrupt(const std::string& id) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = sessions_.find(id);
    if (it == sessions_.end()) return false;
    it->second->interrupt();
    return true;
}

bool TerminalModel::clear(const std::string& id) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = sessions_.find(id);
    if (it == sessions_.end()) return false;
    it->second->clear();
    return true;
}

bool TerminalModel::restart(const std::string& id) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = sessions_.find(id);
    if (it == sessions_.end()) return false;
    it->second->restart();
    return true;
}

std::vector<std::string> TerminalModel::sessionIds() const {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<std::string> ids;
    ids.reserve(sessions_.size());
    for (const auto& [id, session] : sessions_) {
        (void)session;
        ids.push_back(id);
    }
    return ids;
}

std::optional<std::string> TerminalModel::currentId() const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (currentId_.empty()) return std::nullopt;
    return currentId_;
}

const TerminalSession* TerminalModel::find(const std::string& id) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = sessions_.find(id);
    return it == sessions_.end() ? nullptr : it->second.get();
}

TerminalSession* TerminalModel::find(const std::string& id) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = sessions_.find(id);
    return it == sessions_.end() ? nullptr : it->second.get();
}

void TerminalModel::setSinks(OutputSink output, ErrorSink error, StateSink state, SessionListSink listChanged) {
    std::lock_guard<std::mutex> lock(mutex_);
    outputSink_ = std::move(output);
    errorSink_ = std::move(error);
    stateSink_ = std::move(state);
    listSink_ = std::move(listChanged);
}

void TerminalModel::attachHandlers(TerminalSession& session) {
    // Captured by value: a workspace switch / shutdown bumps epoch_, after which
    // any callback still in flight on a transport worker is dropped here, before
    // it can be marshaled into the (possibly torn-down) Qt panel.
    const auto capturedEpoch = epoch_.load();
    auto wrapOutput = [this, capturedEpoch](const std::string& id, const std::string& bytes) {
        if (epoch_.load() != capturedEpoch) return;
        OutputSink sink;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            sink = outputSink_;
        }
        if (sink) sink(id, bytes);
    };
    auto wrapError = [this, capturedEpoch](const std::string& id, const std::string& message) {
        if (epoch_.load() != capturedEpoch) return;
        ErrorSink sink;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            sink = errorSink_;
        }
        if (sink) sink(id, message);
    };
    auto wrapState = [this, capturedEpoch](const std::string& id, TerminalSession::State state,
                                           const std::optional<int>& exitCode) {
        if (epoch_.load() != capturedEpoch) return;
        StateSink sink;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            sink = stateSink_;
        }
        if (sink) sink(id, state, exitCode);
    };
    session.setSinks(wrapOutput, wrapError, wrapState);
}

void TerminalModel::notifyListChanged() {
    SessionListSink sink;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        sink = listSink_;
    }
    if (sink) sink();
}

} // namespace lithe::windows::app
