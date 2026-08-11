#include "terminal_status_bar.h"

#include "terminal_session.h"

#include <QAction>
#include <QFont>
#include <QFontMetrics>
#include <QHBoxLayout>
#include <QLabel>
#include <QMenu>
#include <QStyle>
#include <QToolButton>

#include <chrono>
#include <string>

namespace {

const char kRunningDotCss[] = "background:#2ea043;border-radius:3px;";
const char kStoppedDotCss[] = "background:#8b949e;border-radius:3px;";

} // namespace

TerminalStatusBar::TerminalStatusBar(QWidget* parent)
    : QWidget(parent),
      dot_(makeLabel()),
      titleLabel_(makeLabel()),
      dirLabel_(makeLabel()),
      elapsedLabel_(makeLabel()),
      exitLabel_(makeLabel()),
      newButton_(makeToolButton(QStringLiteral("+"), tr("New terminal session"))),
      shellMenuButton_(makeToolButton(QStringLiteral("∨"), tr("New terminal with shell"))),
      moreMenuButton_(makeToolButton(QStringLiteral("…"), tr("Terminal actions"))),
      closeButton_(makeToolButton(QStringLiteral("−"), tr("Close the current terminal session"))),
      shellMenu_(new QMenu(this)),
      moreMenu_(new QMenu(this)) {
    setObjectName(QStringLiteral("terminalStatusBar"));
    setAttribute(Qt::WA_StyledBackground, true);
    setFixedHeight(30);

    dot_->setFixedSize(6, 6);
    titleLabel_->setMaximumWidth(120);
    dirLabel_->setMaximumWidth(160);
    dirLabel_->setObjectName(QStringLiteral("terminalStatusMeta"));
    elapsedLabel_->setObjectName(QStringLiteral("terminalStatusMeta"));
    exitLabel_->setObjectName(QStringLiteral("terminalStatusExit"));

    // Mac status typography: secondary color for the title, tertiary for the
    // directory and elapsed readouts; sizes in logical px matching Mac points.
    setStyleSheet(QStringLiteral(R"(
        QWidget#terminalStatusBar { background: #1f2124; }
        QWidget#terminalStatusBar QLabel {
            background: transparent;
            color: #808080;
            font-size: 10.5px;
        }
        QWidget#terminalStatusBar QLabel#terminalStatusMeta { color: #575757; }
        QWidget#terminalStatusBar QToolButton {
            color: #808080;
            background: transparent;
            border: 0;
            border-radius: 5px;
            font-size: 12px;
        }
        QWidget#terminalStatusBar QToolButton:hover {
            background: rgba(255, 255, 255, 14);
        }
        QWidget#terminalStatusBar QToolButton:pressed {
            background: rgba(255, 255, 255, 24);
        }
    )"));

    shellMenuButton_->setPopupMode(QToolButton::InstantPopup);
    shellMenuButton_->setMenu(shellMenu_);
    moreMenuButton_->setPopupMode(QToolButton::InstantPopup);
    moreMenuButton_->setMenu(moreMenu_);
    buildMoreMenu();

    auto* layout = new QHBoxLayout(this);
    layout->setContentsMargins(0, 0, 7, 0);
    layout->setSpacing(5);
    layout->addWidget(dot_);
    layout->addWidget(titleLabel_);
    layout->addWidget(dirLabel_);
    layout->addWidget(elapsedLabel_);
    layout->addWidget(exitLabel_);
    layout->addWidget(newButton_);
    layout->addWidget(shellMenuButton_);
    layout->addWidget(moreMenuButton_);
    layout->addWidget(closeButton_);

    // Fixed minimum width keeps the ticking readout from shifting the buttons.
    elapsedLabel_->setMinimumWidth(
        fontMetrics().horizontalAdvance(QStringLiteral("00:00:00")) + 4);

    connect(newButton_, &QToolButton::clicked, this, &TerminalStatusBar::newSessionRequested);
    connect(closeButton_, &QToolButton::clicked, this, &TerminalStatusBar::closeRequested);
    connect(shellMenu_, &QMenu::triggered, this, [this](QAction* action) {
        const QString shell = action->data().toString();
        if (!shell.isEmpty()) emit newSessionWithShellRequested(shell);
    });
}

void TerminalStatusBar::updateFromSession(const lithe::windows::app::TerminalSession* session) {
    if (session == nullptr) {
        dot_->setStyleSheet(QLatin1String(kStoppedDotCss));
        titleLabel_->clear();
        dirLabel_->clear();
        elapsedLabel_->clear();
        exitLabel_->clear();
        return;
    }

    const bool running = session->state() == lithe::windows::ProcessLifecycleState::Running;
    dot_->setStyleSheet(QLatin1String(running ? kRunningDotCss : kStoppedDotCss));

    titleLabel_->setText(elided(QString::fromStdString(session->displayName()), titleLabel_));
    dirLabel_->setText(elided(QString::fromStdString(session->directoryName()), dirLabel_));
    elapsedLabel_->setText(QString::fromStdString(
        session->elapsedDescription(std::chrono::system_clock::now())));

    if (session->exitCode().has_value()) {
        const int code = *session->exitCode();
        exitLabel_->setText(QStringLiteral("Exit %1").arg(code));
        // Mac status bar: green for a clean exit, orange for a failure.
        exitLabel_->setStyleSheet(code == 0 ? QStringLiteral("color:#47b863;")
                                            : QStringLiteral("color:#e8a133;"));
    } else {
        exitLabel_->clear();
    }
}

void TerminalStatusBar::setAvailableShells(const QStringList& shells) {
    shells_ = shells;
    buildShellMenu();
}

QString TerminalStatusBar::snapshotText() const {
    QStringList parts;
    parts << (dot_->styleSheet().contains(QStringLiteral("#2ea043")) ? QStringLiteral("G")
                                                                     : QStringLiteral("D"));
    const auto labels = {titleLabel_->text(), dirLabel_->text(), elapsedLabel_->text(),
                         exitLabel_->text()};
    for (const auto& text : labels) {
        if (!text.isEmpty()) parts << text;
    }
    return parts.join(QStringLiteral("|"));
}

QLabel* TerminalStatusBar::makeLabel() {
    auto* label = new QLabel(this);
    label->setContentsMargins(0, 0, 0, 0);
    return label;
}

QToolButton* TerminalStatusBar::makeToolButton(const QString& text, const QString& toolTip) {
    auto* button = new QToolButton(this);
    button->setText(text);
    button->setToolTip(toolTip);
    button->setAutoRaise(true);
    button->setFixedSize(26, 26);
    button->setCursor(Qt::PointingHandCursor);
    return button;
}

QString TerminalStatusBar::elided(const QString& text, const QLabel* label) const {
    const int width = qMax(1, label->maximumWidth());
    const QString elidedText = fontMetrics().elidedText(text, Qt::ElideRight, width);
    return elidedText.isEmpty() ? QString() : elidedText;
}

void TerminalStatusBar::buildShellMenu() {
    shellMenu_->clear();
    for (const auto& shell : shells_) {
        auto* action = shellMenu_->addAction(tr("New %1").arg(shell));
        action->setData(shell);
    }
    if (shellMenu_->isEmpty()) {
        shellMenu_->addAction(tr("No shells available"))->setEnabled(false);
    }
}

void TerminalStatusBar::buildMoreMenu() {
    auto* interrupt = moreMenu_->addAction(tr("Interrupt"));
    auto* restart = moreMenu_->addAction(tr("Restart"));
    auto* clear = moreMenu_->addAction(tr("Clear"));
    moreMenu_->addSeparator();
    auto* close = moreMenu_->addAction(tr("Close Terminal"));
    connect(interrupt, &QAction::triggered, this, &TerminalStatusBar::interruptRequested);
    connect(restart, &QAction::triggered, this, &TerminalStatusBar::restartRequested);
    connect(clear, &QAction::triggered, this, &TerminalStatusBar::clearRequested);
    connect(close, &QAction::triggered, this, &TerminalStatusBar::closeRequested);
}
