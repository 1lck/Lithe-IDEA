#pragma once

#include <QString>
#include <QStringList>
#include <QWidget>

class QLabel;
class QMenu;
class QToolButton;

namespace lithe::windows::app {
class TerminalSession;
}

// The right-aligned status bar that sits in the terminal header row, next to
// the tabs (QTabWidget corner widget). Presentation only: it re-reads the
// active session's state and emits requests for the panel to act on. A 1-second
// timer on the panel drives updateFromSession so the elapsed readout ticks.
class TerminalStatusBar : public QWidget {
    Q_OBJECT

public:
    explicit TerminalStatusBar(QWidget* parent = nullptr);

    // Re-reads the active session's display metadata and lifecycle state. A null
    // session clears every label. Never locks the model; TerminalSession
    // accessors are lock-guarded individually.
    void updateFromSession(const lithe::windows::app::TerminalSession* session);

    // Feeds the "new with shell" (∨) menu. Clears previous entries.
    void setAvailableShells(const QStringList& shells);

    // Concatenated snapshot of the current labels for tests, e.g.
    // "G|cmd.exe|Lithe-IDEA|00:04|Exit 0". Empty labels are skipped.
    QString snapshotText() const;

signals:
    void newSessionRequested();
    void newSessionWithShellRequested(const QString& shellPath);
    void interruptRequested();
    void restartRequested();
    void clearRequested();
    void closeRequested();

private:
    QLabel* dot_;
    QLabel* titleLabel_;
    QLabel* dirLabel_;
    QLabel* elapsedLabel_;
    QLabel* exitLabel_;
    QToolButton* newButton_;
    QToolButton* shellMenuButton_;
    QToolButton* moreMenuButton_;
    QToolButton* closeButton_;
    QMenu* shellMenu_;
    QMenu* moreMenu_;
    QStringList shells_;

    QLabel* makeLabel();
    QToolButton* makeToolButton(const QString& text, const QString& toolTip);
    QString elided(const QString& text, const QLabel* label) const;
    void buildShellMenu();
    void buildMoreMenu();
};
