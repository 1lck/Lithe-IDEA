#include "terminal_panel.h"

#include "terminal_model.h"
#include "terminal_session.h"
#include "terminal_status_bar.h"
#include "terminal_view.h"
#include "ui_translation.h"

#include <QHBoxLayout>
#include <QLabel>
#include <QStackedWidget>
#include <QTabBar>
#include <QTimer>
#include <QToolButton>
#include <QVBoxLayout>

#include <optional>
#include <string>

TerminalPanel::TerminalPanel(QWidget* parent)
    : QWidget(parent),
      statusBar_(new TerminalStatusBar(this)),
      timer_(new QTimer(this)),
      tabBar_(new QTabBar(this)),
      stack_(new QStackedWidget(this)) {
    tabBar_->setObjectName(QStringLiteral("terminalTabBar"));
    tabBar_->setTabsClosable(false);  // per-tab × buttons are installed manually (Mac style)
    tabBar_->setMovable(false);
    tabBar_->setDocumentMode(true);
    tabBar_->setDrawBase(false);
    tabBar_->setUsesScrollButtons(false);
    tabBar_->setExpanding(false);
    stack_->setObjectName(QStringLiteral("terminalStack"));

    // One header row holds the prefix, the tab strip, and the status bar so they
    // share the same vertical centerline — the Mac terminal's single-line chrome.
    auto* header = new QWidget(this);
    header->setObjectName(QStringLiteral("terminalHeader"));
    header->setAttribute(Qt::WA_StyledBackground, true);
    header->setFixedHeight(30);
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(12, 0, 7, 0);
    headerLayout->setSpacing(0);
    headerLayout->addWidget(buildHeaderPrefix(), 0, Qt::AlignVCenter);
    headerLayout->addSpacing(8);
    headerLayout->addWidget(tabBar_, 0, Qt::AlignVCenter);
    headerLayout->addStretch(1);
    headerLayout->addWidget(statusBar_, 0, Qt::AlignVCenter);

    // Terminal-scoped chrome: the global app theme styles QTabBar with a teal
    // underline; the terminal overrides it with the Mac pill style. Values are
    // logical px chosen to match the Mac theme points 1:1.
    setStyleSheet(QStringLiteral(R"(
        QWidget#terminalHeader { background: #1f2124; }
        QStackedWidget#terminalStack {
            background: #121315;
            border-top: 1px solid #303133;
        }
        QTabBar#terminalTabBar { background: transparent; }
        QTabBar#terminalTabBar::tab {
            background: transparent;
            color: #808080;
            border: 1px solid transparent;
            border-radius: 5px;
            font-size: 11.5px;
            min-height: 22px;
            padding: 2px 6px 2px 9px;
            margin: 2px 1px;
        }
        QTabBar#terminalTabBar::tab:hover {
            background: rgba(255, 255, 255, 14);
        }
        QTabBar#terminalTabBar::tab:selected {
            background: #34383d;
            color: #dbdbdb;
            border-color: rgba(79, 148, 250, 217);
        }
        QLabel#terminalHeaderGlyph {
            color: #808080;
            font-size: 12px;
            background: transparent;
        }
        QLabel#terminalHeaderTitle {
            color: #dbdbdb;
            font-size: 12.5px;
            font-weight: 600;
            background: transparent;
        }
        QToolButton#terminalTabClose {
            color: #808080;
            background: transparent;
            border: 0;
            border-radius: 3px;
            font-size: 10px;
            font-weight: 600;
            padding: 0px;
        }
        QToolButton#terminalTabClose:hover {
            background: rgba(255, 255, 255, 14);
        }
        QToolButton#terminalTabClose:pressed {
            background: rgba(255, 255, 255, 24);
        }
    )"));

    timer_->setInterval(1000);
    connect(timer_, &QTimer::timeout, this, &TerminalPanel::updateStatusBar);
    timer_->start();

    connect(statusBar_, &TerminalStatusBar::newSessionRequested,
            this, [this]() { newSession(); });
    connect(statusBar_, &TerminalStatusBar::newSessionWithShellRequested,
            this, &TerminalPanel::newSessionWithShell);
    connect(statusBar_, &TerminalStatusBar::interruptRequested,
            this, &TerminalPanel::interruptCurrent);
    connect(statusBar_, &TerminalStatusBar::restartRequested,
            this, &TerminalPanel::restartCurrent);
    connect(statusBar_, &TerminalStatusBar::clearRequested,
            this, &TerminalPanel::clearCurrent);
    connect(statusBar_, &TerminalStatusBar::closeRequested,
            this, &TerminalPanel::closeCurrent);

    connect(tabBar_, &QTabBar::currentChanged, this, &TerminalPanel::handleTabChanged);

    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);
    layout->addWidget(header);
    layout->addWidget(stack_, 1);
}

TerminalPanel::~TerminalPanel() {
    // Drop our sinks before the QObject goes away so the model never invokes a
    // freed panel. The model's own epoch also guards in-flight callbacks.
    if (model_ != nullptr) {
        model_->setSinks({}, {}, {}, {});
    }
}

void TerminalPanel::setModel(lithe::windows::app::TerminalModel* model) {
    model_ = model;
    attachModelSinks();
    syncSessions();
}

void TerminalPanel::setWorkspace(const QString& workingDirectory,
                                 const std::map<std::string, std::string>& environment) {
    workingDirectory_ = workingDirectory;
    environment_ = environment;
}

void TerminalPanel::setAvailableShells(const QStringList& executablePaths) {
    shells_ = executablePaths;
    statusBar_->setAvailableShells(executablePaths);
}

int TerminalPanel::sessionCount() const {
    return tabBar_->count();
}

QString TerminalPanel::currentSessionId() const {
    TerminalView* view = viewAt(tabBar_->currentIndex());
    return view == nullptr ? QString() : view->sessionId();
}

QString TerminalPanel::renderedText(const QString& sessionId) const {
    TerminalView* view = viewAt(indexOfSession(sessionId));
    return view == nullptr ? QString() : view->text();
}

QString TerminalPanel::tabTitleAt(int index) const {
    if (index < 0 || index >= tabBar_->count()) return QString();
    return tabBar_->tabText(index);
}

QWidget* TerminalPanel::tabCloseButtonAt(int index) const {
    if (index < 0 || index >= tabBar_->count()) return nullptr;
    return tabBar_->tabButton(index, QTabBar::RightSide);
}

QWidget* TerminalPanel::buildHeaderPrefix() {
    auto* prefix = new QWidget(this);
    prefix->setObjectName(QStringLiteral("terminalHeaderPrefix"));
    auto* glyph = new QLabel(QStringLiteral(">_"), prefix);
    glyph->setObjectName(QStringLiteral("terminalHeaderGlyph"));
    auto* title = new QLabel(lithe::windows::uiText(QStringLiteral("Terminal")), prefix);
    title->setObjectName(QStringLiteral("terminalHeaderTitle"));
    auto* layout = new QHBoxLayout(prefix);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(7);
    layout->addWidget(glyph);
    layout->addWidget(title);
    return prefix;
}

void TerminalPanel::installTabCloseButton(int index) {
    auto* button = new QToolButton(tabBar_);
    button->setObjectName(QStringLiteral("terminalTabClose"));
    button->setText(QStringLiteral("×"));
    button->setToolTip(TerminalPanel::tr("Close this terminal session"));
    button->setAutoRaise(true);
    button->setFixedSize(16, 16);
    button->setCursor(Qt::PointingHandCursor);
    tabBar_->setTabButton(index, QTabBar::RightSide, button);
    // Resolve the tab position lazily at click time: indexes shift as sessions
    // close, and the button must close its own (possibly inactive) tab without
    // changing which session is active.
    connect(button, &QToolButton::clicked, this, [this, button]() {
        for (int i = 0; i < tabBar_->count(); ++i) {
            if (tabBar_->tabButton(i, QTabBar::RightSide) == button) {
                handleTabCloseRequested(i);
                return;
            }
        }
    });
}

QString TerminalPanel::newSession() {
    if (model_ == nullptr) return {};
    const QString executable = shells_.value(0);
    return newSessionWithShell(executable);
}

QString TerminalPanel::newSessionWithShell(const QString& shellPath) {
    if (model_ == nullptr) return {};
    if (shellPath.isEmpty()) return {};
    lithe::windows::app::TerminalShellSpec shell;
    shell.executablePath = shellPath.toStdString();
    const auto id = model_->create(shell, workingDirectory_.toStdString(), environment_);
    if (id.empty()) return {};
    ensureTab(QString::fromStdString(id));
    updateStatusBar();
    return QString::fromStdString(id);
}

void TerminalPanel::closeCurrent() {
    const QString id = currentSessionId();
    if (id.isEmpty() || model_ == nullptr) return;
    model_->close(id.toStdString());
    syncSessions();
    updateStatusBar();
}

void TerminalPanel::selectSession(const QString& sessionId) {
    const int index = indexOfSession(sessionId);
    if (index >= 0) tabBar_->setCurrentIndex(index);
}

void TerminalPanel::clearCurrent() {
    const QString id = currentSessionId();
    if (id.isEmpty() || model_ == nullptr) return;
    model_->clear(id.toStdString());
    refreshView(id);
}

void TerminalPanel::interruptCurrent() {
    const QString id = currentSessionId();
    if (id.isEmpty() || model_ == nullptr) return;
    model_->interrupt(id.toStdString());
}

void TerminalPanel::restartCurrent() {
    const QString id = currentSessionId();
    if (id.isEmpty() || model_ == nullptr) return;
    model_->restart(id.toStdString());
    refreshView(id);
}

void TerminalPanel::handleTabChanged(int index) {
    if (index >= 0 && index < stack_->count()) stack_->setCurrentIndex(index);
    if (model_ == nullptr || index < 0) return;
    TerminalView* view = viewAt(index);
    if (view == nullptr) return;
    model_->select(view->sessionId().toStdString());
    view->refresh();
    updateStatusBar();
    // Mirror the Mac surface's requestInputFocus: typing goes to the surface of
    // the now-active session.
    view->requestInputFocus();
}

void TerminalPanel::handleTabCloseRequested(int index) {
    if (model_ == nullptr) return;
    TerminalView* view = viewAt(index);
    if (view == nullptr) return;
    model_->close(view->sessionId().toStdString());
    syncSessions();
    updateStatusBar();
}

void TerminalPanel::refreshView(const QString& sessionId) {
    (void)sessionId;
    if (model_ == nullptr) return;
    // One coalesced flush drains every session's view (each render is capped by
    // TerminalView) and closes the model's coalescing window, so a burst of
    // output from any session schedules exactly one UI refresh per cycle. The
    // buffer in the model is the source of truth; views only render snapshots.
    for (int i = 0; i < tabBar_->count(); ++i) {
        TerminalView* view = viewAt(i);
        if (view == nullptr) continue;
        const auto* session = model_->find(view->sessionId().toStdString());
        tabBar_->setTabText(i, tabTitleFor(i, session));
        view->refresh();
    }
    model_->flushPending();
    updateStatusBar();
}

void TerminalPanel::updateStatusBar() {
    if (statusBar_ == nullptr) return;
    statusBar_->updateFromSession(activeSession());
}

const lithe::windows::app::TerminalSession* TerminalPanel::activeSession() const {
    if (model_ == nullptr) return nullptr;
    const auto current = model_->currentId();
    if (!current.has_value()) return nullptr;
    return model_->find(*current);
}

void TerminalPanel::syncSessions() {
    if (model_ == nullptr) return;
    const auto ids = model_->sessionIds();
    for (int i = tabBar_->count() - 1; i >= 0; --i) {
        TerminalView* view = viewAt(i);
        const QString tabId = view == nullptr ? QString() : view->sessionId();
        bool found = false;
        for (const auto& modelId : ids) {
            if (modelId == tabId.toStdString()) { found = true; break; }
        }
        if (!found) {
            tabBar_->removeTab(i);
            QWidget* page = stack_->widget(i);
            stack_->removeWidget(page);
            page->deleteLater();
        }
    }
    for (const auto& modelId : ids) {
        ensureTab(QString::fromStdString(modelId));
    }
    const auto current = model_->currentId();
    if (current.has_value()) {
        const int index = indexOfSession(QString::fromStdString(*current));
        if (index >= 0 && index != tabBar_->currentIndex()) tabBar_->setCurrentIndex(index);
    }
    updateStatusBar();
}

void TerminalPanel::attachModelSinks() {
    if (model_ == nullptr) return;
    model_->setSinks(
        [this](const std::string& id, const std::string&) {
            QMetaObject::invokeMethod(this, "refreshView", Qt::QueuedConnection,
                                      Q_ARG(QString, QString::fromStdString(id)));
        },
        [this](const std::string& id, const std::string&) {
            QMetaObject::invokeMethod(this, "refreshView", Qt::QueuedConnection,
                                      Q_ARG(QString, QString::fromStdString(id)));
        },
        [this](const std::string& id, lithe::windows::app::TerminalSession::State,
               const std::optional<int>&) {
            QMetaObject::invokeMethod(this, "refreshView", Qt::QueuedConnection,
                                      Q_ARG(QString, QString::fromStdString(id)));
        },
        [this]() {
            QMetaObject::invokeMethod(this, "syncSessions", Qt::QueuedConnection);
        });
}

int TerminalPanel::indexOfSession(const QString& sessionId) const {
    for (int i = 0; i < tabBar_->count(); ++i) {
        TerminalView* view = viewAt(i);
        if (view != nullptr && view->sessionId() == sessionId) return i;
    }
    return -1;
}

TerminalView* TerminalPanel::viewAt(int index) const {
    if (index < 0 || index >= stack_->count()) return nullptr;
    return qobject_cast<TerminalView*>(stack_->widget(index));
}

QString TerminalPanel::tabTitleFor(int index,
                                   const lithe::windows::app::TerminalSession* session) const {
    if (session == nullptr) return QString();
    // Process title if set; otherwise the index-based "Local" naming macOS uses
    // (Local, Local (2), Local (3), ...).
    QString base;
    const auto& processTitle = session->processTitle();
    if (!processTitle.empty()) {
        base = QString::fromStdString(processTitle);
    } else {
        base = index == 0 ? QStringLiteral("Local")
                          : QStringLiteral("Local (%1)").arg(index + 1);
    }
    switch (session->state()) {
        case lithe::windows::ProcessLifecycleState::Starting:
            return base + QStringLiteral(" …");
        case lithe::windows::ProcessLifecycleState::Running:
            return base;
        case lithe::windows::ProcessLifecycleState::Stopping:
            return base + TerminalPanel::tr(" (stopping)");
        case lithe::windows::ProcessLifecycleState::Finished:
            return base + TerminalPanel::tr(" (exited)");
        case lithe::windows::ProcessLifecycleState::Failed:
            return base + TerminalPanel::tr(" (failed)");
    }
    return base;
}

void TerminalPanel::ensureTab(const QString& sessionId) {
    if (indexOfSession(sessionId) >= 0) {
        refreshView(sessionId);
        return;
    }
    auto* view = new TerminalView(this);
    view->bind(model_, sessionId);
    const int index = tabBar_->addTab(QString());
    stack_->insertWidget(index, view);
    installTabCloseButton(index);
    const auto* session = model_->find(sessionId.toStdString());
    tabBar_->setTabText(index, tabTitleFor(index, session));
    const bool isModelCurrent = model_ != nullptr && model_->currentId().has_value() &&
                                QString::fromStdString(*model_->currentId()) == sessionId;
    if (isModelCurrent || tabBar_->currentIndex() < 0) {
        // handleTabChanged syncs the stack page and input focus.
        tabBar_->setCurrentIndex(index);
    }
}
