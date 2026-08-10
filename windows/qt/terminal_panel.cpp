#include "terminal_panel.h"

#include "terminal_model.h"
#include "terminal_session.h"
#include "terminal_view.h"

#include <QComboBox>
#include <QHBoxLayout>
#include <QPushButton>
#include <QTabWidget>
#include <QVBoxLayout>

#include <optional>
#include <string>

TerminalPanel::TerminalPanel(QWidget* parent)
    : QWidget(parent),
      shellBox_(new QComboBox(this)),
      newButton_(new QPushButton(TerminalPanel::tr("New"), this)),
      closeButton_(new QPushButton(TerminalPanel::tr("Close"), this)),
      clearButton_(new QPushButton(TerminalPanel::tr("Clear"), this)),
      interruptButton_(new QPushButton(TerminalPanel::tr("Interrupt"), this)),
      restartButton_(new QPushButton(TerminalPanel::tr("Restart"), this)),
      tabs_(new QTabWidget(this)) {
    newButton_->setToolTip(TerminalPanel::tr("Open a new terminal session"));
    closeButton_->setToolTip(TerminalPanel::tr("Close the current terminal session"));
    clearButton_->setToolTip(TerminalPanel::tr("Clear the current session output"));
    interruptButton_->setToolTip(TerminalPanel::tr("Send Ctrl+C to the current session"));
    restartButton_->setToolTip(TerminalPanel::tr("Restart the current session"));

    tabs_->setTabsClosable(true);
    tabs_->setMovable(false);

    auto* toolbar = new QHBoxLayout;
    toolbar->setContentsMargins(0, 0, 0, 0);
    toolbar->addWidget(shellBox_);
    toolbar->addWidget(newButton_);
    toolbar->addWidget(closeButton_);
    toolbar->addStretch();
    toolbar->addWidget(clearButton_);
    toolbar->addWidget(interruptButton_);
    toolbar->addWidget(restartButton_);

    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->addLayout(toolbar);
    layout->addWidget(tabs_);

    connect(newButton_, &QPushButton::clicked, this, &TerminalPanel::newSession);
    connect(closeButton_, &QPushButton::clicked, this, &TerminalPanel::closeCurrent);
    connect(clearButton_, &QPushButton::clicked, this, &TerminalPanel::clearCurrent);
    connect(interruptButton_, &QPushButton::clicked, this, &TerminalPanel::interruptCurrent);
    connect(restartButton_, &QPushButton::clicked, this, &TerminalPanel::restartCurrent);
    connect(tabs_, &QTabWidget::currentChanged, this, &TerminalPanel::handleTabChanged);
    connect(tabs_, &QTabWidget::tabCloseRequested, this, &TerminalPanel::handleTabCloseRequested);
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
    shellBox_->clear();
    shellBox_->addItems(executablePaths);
    if (shellBox_->count() > 0) shellBox_->setCurrentIndex(0);
}

int TerminalPanel::sessionCount() const {
    return tabs_->count();
}

QString TerminalPanel::currentSessionId() const {
    TerminalView* view = viewAt(tabs_->currentIndex());
    return view == nullptr ? QString() : view->sessionId();
}

QString TerminalPanel::renderedText(const QString& sessionId) const {
    TerminalView* view = viewAt(indexOfSession(sessionId));
    return view == nullptr ? QString() : view->text();
}

QString TerminalPanel::newSession() {
    if (model_ == nullptr) return {};
    const QString executable = shellBox_->count() > 0 ? shellBox_->currentText() : shells_.value(0);
    if (executable.isEmpty()) return {};
    lithe::windows::app::TerminalShellSpec shell;
    shell.executablePath = executable.toStdString();
    const auto id = model_->create(shell, workingDirectory_.toStdString(), environment_);
    if (id.empty()) return {};
    ensureTab(QString::fromStdString(id));
    return QString::fromStdString(id);
}

void TerminalPanel::closeCurrent() {
    const QString id = currentSessionId();
    if (id.isEmpty() || model_ == nullptr) return;
    model_->close(id.toStdString());
    syncSessions();
}

void TerminalPanel::selectSession(const QString& sessionId) {
    const int index = indexOfSession(sessionId);
    if (index >= 0) tabs_->setCurrentIndex(index);
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
    if (model_ == nullptr || index < 0) return;
    TerminalView* view = viewAt(index);
    if (view == nullptr) return;
    model_->select(view->sessionId().toStdString());
    view->refresh();
}

void TerminalPanel::handleTabCloseRequested(int index) {
    if (model_ == nullptr) return;
    TerminalView* view = viewAt(index);
    if (view == nullptr) return;
    model_->close(view->sessionId().toStdString());
    syncSessions();
}

void TerminalPanel::refreshView(const QString& sessionId) {
    const int index = indexOfSession(sessionId);
    if (index < 0) return;
    tabs_->setTabText(index, tabTitleFor(sessionId));
    TerminalView* view = viewAt(index);
    if (view != nullptr) view->refresh();
}

void TerminalPanel::syncSessions() {
    if (model_ == nullptr) return;
    const auto ids = model_->sessionIds();
    for (int i = tabs_->count() - 1; i >= 0; --i) {
        TerminalView* view = viewAt(i);
        const QString tabId = view == nullptr ? QString() : view->sessionId();
        bool found = false;
        for (const auto& modelId : ids) {
            if (modelId == tabId.toStdString()) { found = true; break; }
        }
        if (!found) {
            QWidget* page = tabs_->widget(i);
            tabs_->removeTab(i);
            page->deleteLater();
        }
    }
    for (const auto& modelId : ids) {
        ensureTab(QString::fromStdString(modelId));
    }
    const auto current = model_->currentId();
    if (current.has_value()) {
        const int index = indexOfSession(QString::fromStdString(*current));
        if (index >= 0 && index != tabs_->currentIndex()) tabs_->setCurrentIndex(index);
    }
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
    for (int i = 0; i < tabs_->count(); ++i) {
        TerminalView* view = viewAt(i);
        if (view != nullptr && view->sessionId() == sessionId) return i;
    }
    return -1;
}

TerminalView* TerminalPanel::viewAt(int index) const {
    if (index < 0 || index >= tabs_->count()) return nullptr;
    return qobject_cast<TerminalView*>(tabs_->widget(index));
}

QString TerminalPanel::tabTitleFor(const QString& sessionId) const {
    if (model_ == nullptr) return sessionId;
    const auto* session = model_->find(sessionId.toStdString());
    if (session == nullptr) return sessionId;
    QString base = QString::fromStdString(session->title());
    if (base.isEmpty()) base = sessionId;
    switch (session->state()) {
        case lithe::windows::ProcessLifecycleState::Starting: return base + " …";
        case lithe::windows::ProcessLifecycleState::Running: return base;
        case lithe::windows::ProcessLifecycleState::Stopping: return base + TerminalPanel::tr(" (stopping)");
        case lithe::windows::ProcessLifecycleState::Finished: return base + TerminalPanel::tr(" (exited)");
        case lithe::windows::ProcessLifecycleState::Failed: return base + TerminalPanel::tr(" (failed)");
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
    const int index = tabs_->addTab(view, tabTitleFor(sessionId));
    if (model_ != nullptr) {
        const auto current = model_->currentId();
        if (current.has_value() && QString::fromStdString(*current) == sessionId) {
            tabs_->setCurrentIndex(index);
        }
    }
    if (tabs_->currentIndex() < 0) tabs_->setCurrentIndex(index);
}
