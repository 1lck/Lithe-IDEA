#pragma once

#include "terminal_model.h"

#include <QMap>
#include <QString>
#include <QStringList>
#include <QWidget>

#include <map>
#include <string>

class QStackedWidget;
class QTabBar;
class QTimer;
class TerminalStatusBar;
class TerminalView;

namespace lithe::windows::app {
class TerminalModel;
class TerminalSession;
}

// Multi-session terminal UI matching the macOS terminal chrome: one custom
// header row holds the glyph + title, the session QTabBar, and the right-aligned
// TerminalStatusBar so every item shares the same vertical centerline; a
// QStackedWidget below renders the session surfaces. Tab titles are index-based
// ("Local", "Local (2)", ...) unless a session reports a process title. Owns no
// terminal state — it renders from the TerminalModel and forwards every action
// back to it. Model callbacks arrive on transport worker threads, so each sink
// marshals onto the Qt thread via a queued connection before touching widgets.
class TerminalPanel : public QWidget {
    Q_OBJECT

public:
    explicit TerminalPanel(QWidget* parent = nullptr);
    ~TerminalPanel();

    void setModel(lithe::windows::app::TerminalModel* model);
    void setWorkspace(const QString& workingDirectory,
                      const std::map<std::string, std::string>& environment);
    void setAvailableShells(const QStringList& executablePaths);

    int sessionCount() const;
    QString currentSessionId() const;
    // Snapshot of the rendered output for a session — used by tests and by the
    // status indicator; returns an empty string if the session is unknown.
    QString renderedText(const QString& sessionId) const;

    // Test surface: the tab title at a position, the close button at a
    // position, and the status bar widget.
    QString tabTitleAt(int index) const;
    QWidget* tabCloseButtonAt(int index) const;
    TerminalStatusBar* statusBar() const { return statusBar_; }

public slots:
    // Creates a session for the default (first available) shell, selects it, and
    // returns its id (empty string on failure).
    QString newSession();
    // Creates a session for an explicit shell path and selects it.
    QString newSessionWithShell(const QString& shellPath);
    void selectSession(const QString& sessionId);
    void closeCurrent();
    void clearCurrent();
    void interruptCurrent();
    void restartCurrent();

private slots:
    void handleTabChanged(int index);
    void handleTabCloseRequested(int index);
    void refreshView(const QString& sessionId);
    void syncSessions();
    void updateStatusBar();

private:
    lithe::windows::app::TerminalModel* model_ = nullptr;
    QString workingDirectory_;
    std::map<std::string, std::string> environment_;
    QStringList shells_;

    TerminalStatusBar* statusBar_;
    QTimer* timer_;
    QTabBar* tabBar_;
    QStackedWidget* stack_;

    void attachModelSinks();
    QWidget* buildHeaderPrefix();
    void installTabCloseButton(int index);
    int indexOfSession(const QString& sessionId) const;
    TerminalView* viewAt(int index) const;
    QString tabTitleFor(int index, const lithe::windows::app::TerminalSession* session) const;
    const lithe::windows::app::TerminalSession* activeSession() const;
    void ensureTab(const QString& sessionId);
};
