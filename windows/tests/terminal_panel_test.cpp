#include "fake_terminal_transport.h"
#include "terminal_model.h"
#include "terminal_panel.h"
#include "terminal_status_bar.h"
#include "terminal_view.h"

#include <QApplication>
#include <QCoreApplication>
#include <QLabel>
#include <QLayout>
#include <QString>
#include <QStringList>
#include <QTabBar>
#include <QToolButton>

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

// Task 5.3: the emulator lives in the session, so its screen, scrollback, and
// cursor survive tab switches untouched. The panel only re-selects the session
// and re-renders the same emulator.
void testScreenScrollbackCursorSurviveSwitch() {
    Harness h;
    const auto a = h.panel->newSession();
    const auto b = h.panel->newSession();

    // More lines than the 40-row emulator screen, so scrollback builds up, then
    // a cursor-position move (row 5, column 10 -> 0-based (4, 9)).
    std::string out;
    for (int i = 0; i < 50; ++i) out += "line " + std::to_string(i) + "\r\n";
    out += "\x1b[5;10H";
    h.fakeFor(a)->feed(out);
    pump();

    const auto* s = h.model->find(a.toStdString());
    assert(s != nullptr);
    assert(s->emulator().scrollbackLineCount() > 0);
    assert(s->emulator().cursorRow() == 4);
    assert(s->emulator().cursorCol() == 9);
    assert(s->emulator().renderText(2048).find("line 49") != std::string::npos);

    h.panel->selectSession(b);
    pump();
    h.panel->selectSession(a);
    pump();
    assert(h.panel->currentSessionId() == a);
    const auto* again = h.model->find(a.toStdString());
    assert(again != nullptr);
    assert(again->emulator().scrollbackLineCount() == s->emulator().scrollbackLineCount());
    assert(again->emulator().cursorRow() == 4);
    assert(again->emulator().cursorCol() == 9);
    assert(again->emulator().renderText(2048).find("line 49") != std::string::npos);
}

// Task 5.3: the alternate-screen flag is per-session emulator state and must
// also survive a tab switch (vim/less-style TUIs hold the alt screen).
void testAltScreenSurvivesSwitch() {
    Harness h;
    const auto a = h.panel->newSession();
    const auto b = h.panel->newSession();

    h.fakeFor(a)->feed("\x1b[?1049h");  // enter alternate screen
    pump();
    assert(h.model->find(a.toStdString())->emulator().altScreen());

    h.panel->selectSession(b);
    pump();
    h.panel->selectSession(a);
    pump();
    assert(h.model->find(a.toStdString())->emulator().altScreen());

    h.fakeFor(a)->feed("\x1b[?1049l");  // leave alternate screen
    pump();
    assert(!h.model->find(a.toStdString())->emulator().altScreen());
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

// Task 4.1: tab titles follow the Mac index-based naming ("Local", "Local (2)",
// ...), with the lifecycle suffix only while not simply running.
void testTabTitlesAreIndexBased() {
    Harness h;
    const auto a = h.panel->newSession();
    const auto b = h.panel->newSession();
    const auto c = h.panel->newSession();
    // Immediately after creation every session is still Starting, so the titles
    // carry the " …" suffix.
    assert(contains(h.panel->tabTitleAt(0), QStringLiteral("Local")));
    assert(contains(h.panel->tabTitleAt(1), QStringLiteral("Local (2)")));
    assert(contains(h.panel->tabTitleAt(2), QStringLiteral("Local (3)")));

    h.fakeFor(a)->emitState(ProcessLifecycleState::Running);
    h.fakeFor(b)->emitState(ProcessLifecycleState::Running);
    h.fakeFor(c)->emitState(ProcessLifecycleState::Running);
    pump();
    assert(h.panel->tabTitleAt(0) == QStringLiteral("Local"));
    assert(h.panel->tabTitleAt(1) == QStringLiteral("Local (2)"));
    assert(h.panel->tabTitleAt(2) == QStringLiteral("Local (3)"));

    // A failure surfaces as a legible state suffix on the base title.
    h.fakeFor(b)->emitState(ProcessLifecycleState::Failed);
    pump();
    assert(contains(h.panel->tabTitleAt(1), QStringLiteral("Local (2)")));
    assert(contains(h.panel->tabTitleAt(1), QStringLiteral("(failed)")));
    // Removing the failed session makes the survivors renumber by index.
    h.panel->selectSession(b);
    h.panel->closeCurrent();
    pump();
    assert(h.panel->sessionCount() == 2);
    assert(h.panel->tabTitleAt(0) == QStringLiteral("Local"));
    assert(h.panel->tabTitleAt(1) == QStringLiteral("Local (2)"));
    (void)a;
    (void)c;
}

// Task 4.1: the status bar shows the active session's dot state, display title,
// working-directory name, elapsed readout, and exit code.
void testStatusBarReflectsActiveSession() {
    Harness h;
    const auto id = h.panel->newSession();
    h.fakeFor(id)->emitState(ProcessLifecycleState::Running);
    pump();

    const auto snapshot = h.panel->statusBar()->snapshotText();
    assert(contains(snapshot, QStringLiteral("G|")));
    assert(contains(snapshot, QStringLiteral("cmd.exe")));
    assert(contains(snapshot, QStringLiteral("proj")));  // last path component of "C:/proj"

    h.fakeFor(id)->emitState(ProcessLifecycleState::Finished, 0);
    pump();
    const auto afterExit = h.panel->statusBar()->snapshotText();
    assert(contains(afterExit, QStringLiteral("D|")));
    assert(contains(afterExit, QStringLiteral("Exit 0")));
}

// Task 4.2: creating a session with an explicit shell (the ∨ menu path) launches
// that shell and makes the session active.
void testNewSessionWithShellViaVMenu() {
    Harness h;
    h.panel->statusBar()->newSessionWithShellRequested("C:/Windows/System32/powershell.exe");
    pump();
    assert(h.panel->sessionCount() == 1);
    const auto id = h.panel->currentSessionId();
    assert(!id.isEmpty());
    const auto* session = h.model->find(id.toStdString());
    assert(session != nullptr);
    assert(session->displayName() == "powershell.exe");
}

// Task 4.2: the − button (closeRequested) closes only the current session.
void testCloseViaStatusBarMinus() {
    Harness h;
    const auto a = h.panel->newSession();
    const auto b = h.panel->newSession();
    h.panel->selectSession(a);
    h.panel->statusBar()->closeRequested();
    pump();
    assert(h.panel->sessionCount() == 1);
    assert(h.panel->currentSessionId() == b);
    assert(h.model->find(a.toStdString()) == nullptr);
    assert(h.model->find(b.toStdString()) != nullptr);
}

// Task 5.1 (chrome parity): the Mac-style header shows a terminal glyph plus
// the localized title on the left, and every tab carries its own × button.
void testHeaderPrefixAndTabCloseButtons() {
    Harness h;
    auto* title = h.panel->findChild<QLabel*>(QStringLiteral("terminalHeaderTitle"));
    assert(title != nullptr);
    assert(!title->text().isEmpty());  // "Terminal" or localized "终端"
    auto* glyph = h.panel->findChild<QLabel*>(QStringLiteral("terminalHeaderGlyph"));
    assert(glyph != nullptr);
    assert(glyph->text() == QStringLiteral(">_"));

    h.panel->newSession();
    h.panel->newSession();
    auto* close0 = h.panel->tabCloseButtonAt(0);
    auto* close1 = h.panel->tabCloseButtonAt(1);
    assert(close0 != nullptr);
    assert(close1 != nullptr);
    // Task 2.2 (chrome polish): Mac-style small trailing close buttons.
    assert(close0->sizeHint() == QSize(16, 16));
    assert(close1->sizeHint() == QSize(16, 16));
}

// Task 1.2 (chrome polish): the title, tab strip, and status bar all live in one
// header row, vertically centered on the same line as on macOS.
void testHeaderItemsShareVerticalCenter() {
    Harness h;
    h.panel->newSession();
    h.panel->resize(900, 400);
    h.panel->show();
    pump();

    auto* prefix = h.panel->findChild<QWidget*>(QStringLiteral("terminalHeaderPrefix"));
    auto* tabBar = h.panel->findChild<QTabBar*>(QStringLiteral("terminalTabBar"));
    assert(prefix != nullptr);
    assert(tabBar != nullptr);
    const int prefixCenterY = prefix->geometry().center().y();
    const int tabBarCenterY = tabBar->geometry().center().y();
    assert(qAbs(prefixCenterY - tabBarCenterY) <= 1);
}

// Task 5.1 (chrome parity): clicking × on an inactive tab closes that session
// and leaves the active session untouched.
void testTabCloseButtonClosesInactiveTab() {
    Harness h;
    const auto a = h.panel->newSession();
    const auto b = h.panel->newSession();
    const auto c = h.panel->newSession();  // newest session is active
    assert(h.panel->currentSessionId() == c);

    auto* closeA = qobject_cast<QToolButton*>(h.panel->tabCloseButtonAt(0));
    assert(closeA != nullptr);
    closeA->click();
    pump();
    assert(h.panel->sessionCount() == 2);
    assert(h.model->find(a.toStdString()) == nullptr);
    assert(h.model->find(b.toStdString()) != nullptr);
    assert(h.panel->currentSessionId() == c);
}

// Task 5.1 (chrome parity): the canvas pads the surface by 8px, as on macOS.
void testCanvasPadding() {
    TerminalView view;
    const auto margins = view.layout()->contentsMargins();
    assert(margins.left() == 8 && margins.top() == 8 &&
           margins.right() == 8 && margins.bottom() == 8);
}

} // namespace

int main(int argc, char** argv) {
    QApplication app(argc, argv);
#define RUN(t) do { fprintf(stderr, "RUN %s\n", #t); fflush(stderr); t(); } while (0)
    RUN(testNewSessionAddsTab);
    RUN(testOutputReachesActiveView);
    RUN(testOutputIsolationBetweenTabs);
    RUN(testSwitchPreservesContent);
    RUN(testScreenScrollbackCursorSurviveSwitch);
    RUN(testAltScreenSurvivesSwitch);
    RUN(testClearOnlyAffectsCurrentSession);
    RUN(testInterruptSendsInterruptByteOnlyToCurrent);
    RUN(testCloseRemovesTab);
    RUN(testRestartRelaunchesCurrent);
    RUN(testTabTitlesAreIndexBased);
    RUN(testStatusBarReflectsActiveSession);
    RUN(testNewSessionWithShellViaVMenu);
    RUN(testCloseViaStatusBarMinus);
    RUN(testHeaderPrefixAndTabCloseButtons);
    RUN(testHeaderItemsShareVerticalCenter);
    RUN(testTabCloseButtonClosesInactiveTab);
    RUN(testCanvasPadding);
#undef RUN
    return 0;
}
