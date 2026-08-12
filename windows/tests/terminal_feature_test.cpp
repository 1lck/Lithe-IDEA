#include "terminal_feature.h"

#include <cassert>

using namespace lithe::windows::app;

int main() {
    TerminalFeatureModel model;
    const auto first = model.create("cmd.exe", "C:/project");
    const auto second = model.create("pwsh.exe", "C:/project/module");
    auto state = model.state();
    const auto createdRevision = state.revision;
    assert(state.sessions.size() == 2);
    assert(state.activeSessionID == second);
    assert(state.sessions[0].id == first && state.sessions[0].shellPath == "cmd.exe");
    assert(state.sessions[1].id == second && state.sessions[1].shellPath == "pwsh.exe");
    assert(state.sessions[0].title == "Terminal 1");
    assert(state.sessions[1].workingDirectory == "C:/project/module");

    assert(model.select(first));
    assert(model.state().revision > createdRevision);
    assert(model.markStarting(first));
    assert(model.markRunning(first));
    assert(model.appendOutput(first, "hello\rworld\n"));
    assert(model.output(first) == "world\n");
    assert(model.setShell(first, "powershell.exe"));
    assert(model.session(first)->shellPath == "powershell.exe");
    assert(model.markExited(first, 7));
    assert(model.session(first)->status == TerminalSessionStatus::Exited);
    assert(model.session(first)->exitCode == 7);

    assert(model.clearOutput(first));
    assert(model.output(first).empty());
    assert(model.markStarting(first));
    assert(!model.session(first)->exitCode);
    assert(model.markRunning(first));
    assert(model.markStopped(first));
    assert(!model.markExited(first));
    assert(!model.setShell(first, {}));
    assert(model.remove(first));
    assert(model.state().activeSessionID == second);
    assert(!model.appendOutput(first, "late output"));

    assert(model.markRunning(second));
    model.reset();
    state = model.state();
    assert(state.sessions.empty() && !state.activeSessionID);
    assert(state.revision > createdRevision);
    assert(model.output(second).empty());
    return 0;
}
