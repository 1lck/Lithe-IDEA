#pragma once

#include "terminal_model.h"

#include <QMap>
#include <QString>
#include <QStringList>
#include <QWidget>

#include <map>
#include <string>

class QTabWidget;
class QComboBox;
class QPushButton;
class QToolButton;
class TerminalView;

namespace lithe::windows::app {
class TerminalModel;
}

// Multi-session terminal UI: a tab per session plus a small action toolbar
// (new / close / clear / interrupt / restart) and a shell selector. Owns no
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

public slots:
    // Creates a session for the currently selected shell, selects it, and
    // returns its id (empty string on failure).
    QString newSession();
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

private:
    lithe::windows::app::TerminalModel* model_ = nullptr;
    QString workingDirectory_;
    std::map<std::string, std::string> environment_;
    QStringList shells_;

    QComboBox* shellBox_;
    QPushButton* newButton_;
    QPushButton* closeButton_;
    QToolButton* clearButton_;
    QToolButton* interruptButton_;
    QToolButton* restartButton_;
    QTabWidget* tabs_;

    void attachModelSinks();
    int indexOfSession(const QString& sessionId) const;
    TerminalView* viewAt(int index) const;
    QString tabTitleFor(const QString& sessionId) const;
    void ensureTab(const QString& sessionId);
};
