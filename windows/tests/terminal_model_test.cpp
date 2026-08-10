#include "fake_terminal_transport.h"
#include "terminal_model.h"

#include <cassert>
#include <map>
#include <string>
#include <vector>

namespace {

using lithe::windows::ProcessLifecycleState;
using lithe::windows::app::TerminalModel;
using lithe::windows::app::TerminalShellSpec;
using lithe::windows::tests::FakeTerminalTransport;

TerminalShellSpec cmdShell() {
    return TerminalShellSpec{"C:/Windows/System32/cmd.exe", {"/Q"}};
}

bool contains(const std::string& haystack, const std::string& needle) {
    return haystack.find(needle) != std::string::npos;
}

bool vectorContains(const std::vector<std::string>& values, const std::string& needle) {
    for (const auto& value : values) {
        if (value == needle) return true;
    }
    return false;
}

struct Harness {
    std::vector<FakeTerminalTransport*> fakes;
    std::unique_ptr<TerminalModel> model;

    Harness() {
        model = std::make_unique<TerminalModel>([this]() -> std::unique_ptr<lithe::windows::TerminalTransport> {
            auto* raw = new FakeTerminalTransport();
            fakes.push_back(raw);
            return std::unique_ptr<lithe::windows::TerminalTransport>(raw);
        });
    }
};

void testCreateSelectAndCurrent() {
    Harness h;
    const auto a = h.model->create(cmdShell(), "C:/proj", {});
    const auto b = h.model->create(cmdShell(), "C:/other", {});
    assert(a == "t1");
    assert(b == "t2");
    assert(h.model->currentId() == "t2");
    assert(h.model->select("t1"));
    assert(h.model->currentId() == "t1");
    assert(!h.model->select("does-not-exist"));
}

void testOutputIsolationBetweenSessions() {
    Harness h;
    h.model->create(cmdShell(), "C:/proj", {});
    h.model->create(cmdShell(), "C:/proj", {});
    h.fakes[0]->feed("hello-A");
    h.fakes[1]->feed("world-B");

    assert(contains(h.model->find("t1")->render(4096), "hello-A"));
    assert(!contains(h.model->find("t1")->render(4096), "world-B"));
    assert(contains(h.model->find("t2")->render(4096), "world-B"));
    assert(!contains(h.model->find("t2")->render(4096), "hello-A"));
}

void testBufferSurvivesSwitch() {
    Harness h;
    h.model->create(cmdShell(), "C:/proj", {});
    h.model->create(cmdShell(), "C:/proj", {});
    h.fakes[0]->feed("first");
    h.model->select("t2");
    h.fakes[0]->feed("second");
    h.model->select("t1");

    const auto rendered = h.model->find("t1")->render(4096);
    assert(contains(rendered, "first"));
    assert(contains(rendered, "second"));
}

void testLifecycleStates() {
    Harness h;
    h.model->create(cmdShell(), "C:/proj", {});
    assert(h.model->find("t1")->state() == ProcessLifecycleState::Starting);
    h.fakes[0]->emitState(ProcessLifecycleState::Running);
    assert(h.model->find("t1")->state() == ProcessLifecycleState::Running);
    h.fakes[0]->emitState(ProcessLifecycleState::Finished, 0);
    assert(h.model->find("t1")->state() == ProcessLifecycleState::Finished);
    assert(h.model->find("t1")->exitCode().has_value());
    assert(*h.model->find("t1")->exitCode() == 0);
}

void testFailedStart() {
    Harness h;
    h.model->create(cmdShell(), "C:/proj", {});
    h.fakes[0]->emitState(ProcessLifecycleState::Failed);
    assert(h.model->find("t1")->state() == ProcessLifecycleState::Failed);
}

void testScopedClearAndInterrupt() {
    Harness h;
    h.model->create(cmdShell(), "C:/proj", {});
    h.model->create(cmdShell(), "C:/proj", {});
    h.fakes[0]->feed("keep-or-clear");
    h.fakes[1]->feed("keep");

    assert(h.model->clear("t1"));
    assert(h.model->find("t1")->render(4096).empty());
    assert(contains(h.model->find("t2")->render(4096), "keep"));

    assert(h.model->interrupt("t1"));
    assert(vectorContains(h.fakes[0]->sends, std::string{'\x03'}));
    assert(h.fakes[1]->sends.empty());

    assert(!h.model->clear("nope"));
    assert(!h.model->interrupt("nope"));
}

void testRestartRelaunchesOnlyTargetAndDropsStaleOutput() {
    Harness h;
    h.model->create(cmdShell(), "C:/proj", {});
    h.model->create(cmdShell(), "C:/proj", {});
    h.fakes[0]->feed("before-restart");

    const auto generationBefore = h.model->find("t1")->generation();
    // Capture the output handler bound during the first launch (generation 1).
    const auto staleOutput = h.fakes[0]->output;
    const auto t1StartsBefore = h.fakes[0]->startCallCount;
    const auto t2StartsBefore = h.fakes[1]->startCallCount;

    assert(h.model->restart("t1"));

    assert(h.model->find("t1")->generation() > generationBefore);
    assert(h.fakes[0]->startCallCount == t1StartsBefore + 1);
    assert(h.fakes[1]->startCallCount == t2StartsBefore); // untouched

    // Late output from the previous launch is dropped via the generation guard.
    staleOutput("STALE-BYTES");
    // Fresh output through the rebound handler flows into the buffer.
    h.fakes[0]->feed("FRESH-BYTES");

    const auto rendered = h.model->find("t1")->render(4096);
    assert(contains(rendered, "FRESH-BYTES"));
    assert(!contains(rendered, "STALE-BYTES"));
}

void testCloseAndDuplicateCloseIsSafe() {
    Harness h;
    h.model->create(cmdShell(), "C:/proj", {});
    h.model->create(cmdShell(), "C:/proj", {});

    h.model->close("t1");
    assert(h.model->find("t1") == nullptr);
    assert(h.model->find("t2") != nullptr);
    // Closing a non-existent session must be a safe no-op.
    h.model->close("t1");
    h.model->close("never-existed");
    assert(vectorContains(h.model->sessionIds(), std::string{"t2"}));
}

void testCloseAllClearsAndBumpsEpoch() {
    Harness h;
    h.model->create(cmdShell(), "C:/proj", {});
    h.model->create(cmdShell(), "C:/proj", {});
    const auto epochBefore = h.model->epoch();

    h.model->closeAll();

    assert(h.model->sessionIds().empty());
    assert(!h.model->currentId().has_value());
    assert(h.model->epoch() > epochBefore);
}

void testShutdownClears() {
    Harness h;
    h.model->create(cmdShell(), "C:/proj", {});
    h.model->shutdown();
    assert(h.model->sessionIds().empty());
}

void testHeavyOutputStaysBounded() {
    Harness h;
    h.model->create(cmdShell(), "C:/proj", {});
    // Feed far more lines than TerminalBuffer::MaximumRows (2000). The buffer
    // must evict the oldest rows so memory stays bounded; a render snapshot
    // must never exceed its cap.
    std::string chunk;
    chunk.reserve(6000 * 8);
    for (int i = 0; i < 6000; ++i) {
        chunk += "L";
        chunk += std::to_string(i);
        chunk += "\n";
    }
    h.fakes[0]->feed(chunk);
    const auto rendered = h.model->find("t1")->render(65536);
    assert(rendered.size() <= 65536);
    // Recent content survived; earliest content was evicted.
    assert(contains(rendered, "L5999"));
    assert(!contains(rendered, "L0"));
    assert(!contains(rendered, "L100"));
}

} // namespace

int main() {
    testCreateSelectAndCurrent();
    testOutputIsolationBetweenSessions();
    testBufferSurvivesSwitch();
    testLifecycleStates();
    testFailedStart();
    testScopedClearAndInterrupt();
    testRestartRelaunchesOnlyTargetAndDropsStaleOutput();
    testCloseAndDuplicateCloseIsSafe();
    testCloseAllClearsAndBumpsEpoch();
    testShutdownClears();
    testHeavyOutputStaysBounded();
    return 0;
}
