#include "fake_terminal_transport.h"
#include "terminal_model.h"
#include "terminal_panel.h"

#include <QApplication>
#include <QCoreApplication>
#include <QString>
#include <QStringList>

#include <cassert>
#include <memory>
#include <string>
#include <vector>

namespace {

using lithe::windows::ProcessLifecycleState;
using lithe::windows::TerminalTransport;
using lithe::windows::app::TerminalModel;
using lithe::windows::app::TerminalShellSpec;
using lithe::windows::tests::FakeTerminalTransport;

bool contains(const QString& haystack, const QString& needle) {
    return haystack.indexOf(needle) >= 0;
}

void pump() {
    // Drain queued meta-calls the model sinks marshaled onto the UI thread.
    QCoreApplication::processEvents(QEventLoop::AllEvents);
    QCoreApplication::processEvents(QEventLoop::AllEvents);
}

struct Harness {
    std::vector<FakeTerminalTransport*> fakes;
    std::unique_ptr<TerminalModel> model;
    std::unique_ptr<TerminalPanel> panel;

    Harness() {
        model = std::make_unique<TerminalModel>([this]() -> std::unique_ptr<TerminalTransport> {
            auto* raw = new FakeTerminalTransport();
            fakes.push_back(raw);
            return std::unique_ptr<TerminalTransport>(raw);
        });
        panel = std::make_unique<TerminalPanel>();
        panel->setModel(model.get());
        panel->setWorkspace("C:/proj", {});
        panel->setAvailableShells(QStringList{"C:/Windows/System32/cmd.exe"});
    }

    FakeTerminalTransport* fakeFor(const QString& id) const {
        // Fakes are pushed in creation order; ids are t1, t2, ... in that order.
        const auto ids = model->sessionIds();
        for (std::size_t i = 0; i < ids.size(); ++i) {
            if (ids[i] == id.toStdString() && i < fakes.size()) return fakes[i];
        }
        return nullptr;
    }
};

void testNewSessionAddsTab() {
    Harness h;
    assert(h.panel->sessionCount() == 0);
    const auto id = h.panel->newSession();
    assert(!id.isEmpty());
    assert(h.panel->sessionCount() == 1);
    assert(h.panel->currentSessionId() == id);
}

void testOutputReachesActiveView() {
    Harness h;
    const auto id = h.panel->newSession();
    h.fakeFor(id)->emitState(ProcessLifecycleState::Running);
    h.fakeFor(id)->feed("hello-panel");
    pump();
    assert(contains(h.panel->renderedText(id), "hello-panel"));
}

void testOutputIsolationBetweenTabs() {
    Harness h;
    const auto a = h.panel->newSession();
    const auto b = h.panel->newSession();
    h.fakeFor(a)->feed("alpha");
    h.fakeFor(b)->feed("beta");
    pump();
    assert(contains(h.panel->renderedText(a), "alpha"));
    assert(!contains(h.panel->renderedText(a), "beta"));
    assert(contains(h.panel->renderedText(b), "beta"));
    assert(!contains(h.panel->renderedText(b), "alpha"));
}

void testSwitchPreservesContent() {
    Harness h;
    const auto a = h.panel->newSession();
    const auto b = h.panel->newSession();
    h.fakeFor(a)->feed("kept-across-switch");
    pump();
    // Switch to b then back to a; a's content must survive both switches.
    h.panel->selectSession(b);
    pump();
    assert(h.panel->currentSessionId() == b);
    h.panel->selectSession(a);
    pump();
    assert(h.panel->currentSessionId() == a);
    assert(contains(h.panel->renderedText(a), "kept-across-switch"));
}

void testClearOnlyAffectsCurrentSession() {
    Harness h;
    const auto a = h.panel->newSession();
    const auto b = h.panel->newSession();
    h.fakeFor(a)->feed("to-clear");
    h.fakeFor(b)->feed("keep");
    pump();
    // Make a the current session and clear it.
    h.panel->selectSession(a);
    h.panel->clearCurrent();
    pump();
    assert(h.panel->renderedText(a).isEmpty());
    assert(contains(h.panel->renderedText(b), "keep"));
}

void testInterruptSendsInterruptByteOnlyToCurrent() {
    Harness h;
    const auto a = h.panel->newSession();
    const auto b = h.panel->newSession();
    h.panel->selectSession(a);
    h.panel->interruptCurrent();
    const std::string expected{'\x03'};
    bool aInterrupted = false;
    for (const auto& send : h.fakeFor(a)->sends) if (send == expected) aInterrupted = true;
    assert(aInterrupted);
    assert(h.fakeFor(b)->sends.empty());
}

void testCloseRemovesTab() {
    Harness h;
    const auto a = h.panel->newSession();
    const auto b = h.panel->newSession();
    assert(h.panel->sessionCount() == 2);
    h.panel->selectSession(b);
    h.panel->closeCurrent();
    pump();
    assert(h.panel->sessionCount() == 1);
    assert(h.panel->currentSessionId() == a);
}

void testRestartRelaunchesCurrent() {
    Harness h;
    const auto a = h.panel->newSession();
    const auto startsBefore = h.fakeFor(a)->startCallCount;
    h.panel->selectSession(a);
    h.panel->restartCurrent();
    pump();
    assert(h.fakeFor(a)->startCallCount == startsBefore + 1);
    assert(h.model->find(a.toStdString()) != nullptr);
    assert(h.model->find(a.toStdString())->generation() >= 2);
}

} // namespace

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    testNewSessionAddsTab();
    testOutputReachesActiveView();
    testOutputIsolationBetweenTabs();
    testSwitchPreservesContent();
    testClearOnlyAffectsCurrentSession();
    testInterruptSendsInterruptByteOnlyToCurrent();
    testCloseRemovesTab();
    testRestartRelaunchesCurrent();
    return 0;
}
