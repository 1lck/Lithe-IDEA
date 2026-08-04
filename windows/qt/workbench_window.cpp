#include "workbench_window.h"

#include <QAction>
#include <QFileDialog>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QKeySequence>
#include <QLineEdit>
#include <QListWidget>
#include <QMetaObject>
#include <QPlainTextEdit>
#include <QSplitter>
#include <QStatusBar>
#include <QToolBar>
#include <QTreeWidget>
#include <QTreeWidgetItem>
#include <QVBoxLayout>
#include <QWidget>

namespace lithe::windows {

namespace {
constexpr int RelativePathRole = Qt::UserRole;
constexpr int DirectoryRole = Qt::UserRole + 1;

QJsonObject responseObject(const QByteArray& response) {
    const auto document = QJsonDocument::fromJson(response);
    return document.isObject() ? document.object() : QJsonObject{};
}

bool responseSucceeded(const QJsonObject& response) {
    return response.value("ok").toBool(false);
}

QString errorMessage(const QJsonObject& response) {
    return response.value("error").toObject().value("message").toString("Core request failed");
}
}

WorkbenchWindow::WorkbenchWindow(std::unique_ptr<DirectoryChangeSource> watcher,
                                 QWidget* parent)
    : QMainWindow(parent), watcher_(std::move(watcher)) {
    setWindowTitle("Lithe");
    resize(1280, 800);

    auto* central = new QWidget(this);
    auto* layout = new QVBoxLayout(central);
    layout->setContentsMargins(0, 0, 0, 0);
    auto* splitter = new QSplitter(Qt::Horizontal, central);

    tree_ = new QTreeWidget(splitter);
    tree_->setHeaderLabel("Workspace");
    tree_->setMinimumWidth(260);
    connect(tree_, &QTreeWidget::itemDoubleClicked, this, &WorkbenchWindow::openTreeItem);

    auto* right = new QWidget(splitter);
    auto* rightLayout = new QVBoxLayout(right);
    rightLayout->setContentsMargins(8, 8, 8, 8);
    searchField_ = new QLineEdit(right);
    searchField_->setPlaceholderText("Search workspace");
    connect(searchField_, &QLineEdit::returnPressed, this, &WorkbenchWindow::searchWorkspace);
    rightLayout->addWidget(searchField_);

    editor_ = new QPlainTextEdit(right);
    editor_->setLineWrapMode(QPlainTextEdit::NoWrap);
    editor_->setPlaceholderText("Open a file from the workspace tree");
    rightLayout->addWidget(editor_, 1);

    results_ = new QListWidget(right);
    results_->setMaximumHeight(170);
    results_->setVisible(false);
    rightLayout->addWidget(results_);

    splitter->addWidget(tree_);
    splitter->addWidget(right);
    splitter->setStretchFactor(1, 1);
    layout->addWidget(splitter);
    setCentralWidget(central);
    buildActions();

    statusBar()->showMessage(QString("Rust Core %1").arg(QString::fromStdString(core_.version())));
}

WorkbenchWindow::~WorkbenchWindow() {
    if (watcher_) watcher_->stop();
}

void WorkbenchWindow::buildActions() {
    auto* toolbar = addToolBar("Workspace");
    auto* open = toolbar->addAction("Open");
    open->setShortcut(QKeySequence::Open);
    connect(open, &QAction::triggered, this, &WorkbenchWindow::chooseWorkspace);
    auto* refresh = toolbar->addAction("Refresh");
    connect(refresh, &QAction::triggered, this, &WorkbenchWindow::refreshWorkspace);
    auto* save = toolbar->addAction("Save");
    save->setShortcut(QKeySequence::Save);
    connect(save, &QAction::triggered, this, &WorkbenchWindow::saveDocument);

    auto* fileMenu = menuBar()->addMenu("File");
    fileMenu->addAction(open);
    fileMenu->addAction(save);
    fileMenu->addAction(refresh);
}

void WorkbenchWindow::chooseWorkspace() {
    const auto root = QFileDialog::getExistingDirectory(this, "Open Workspace", workspaceRoot_);
    if (root.isEmpty()) return;
    workspaceRoot_ = root;
    activePath_.clear();
    editor_->clear();
    if (watcher_) watcher_->start(workspaceRoot_.toStdString(), [this](const std::vector<std::string>&) {
        QMetaObject::invokeMethod(this, &WorkbenchWindow::loadSnapshot, Qt::QueuedConnection);
    });
    loadSnapshot();
}

void WorkbenchWindow::refreshWorkspace() {
    if (workspaceRoot_.isEmpty()) return;
    loadSnapshot();
}

void WorkbenchWindow::loadSnapshot() {
    if (workspaceRoot_.isEmpty()) return;
    const auto response = core_.execute(
        "workspace.snapshot",
        objectPayload(QJsonObject{{"root", workspaceRoot_}}).toStdString());
    const auto object = responseObject(QByteArray::fromStdString(response.json));
    if (!responseSucceeded(object)) { showCoreError(QByteArray::fromStdString(response.json)); return; }
    tree_->clear();
    appendTreeNode(nullptr, object.value("data").toObject().value("root").toObject());
    statusBar()->showMessage(QString("Workspace loaded with %1 files").arg(
        object.value("data").toObject().value("files").toArray().size()));
}

void WorkbenchWindow::appendTreeNode(QTreeWidgetItem* parent, const QJsonObject& node) {
    auto* item = parent == nullptr ? new QTreeWidgetItem(tree_) : new QTreeWidgetItem(parent);
    const auto relativePath = node.value("path").toString();
    item->setText(0, node.value("name").toString());
    item->setData(0, RelativePathRole, relativePath);
    item->setData(0, DirectoryRole, node.value("isDirectory").toBool());
    for (const auto& child : node.value("children").toArray()) appendTreeNode(item, child.toObject());
    if (parent == nullptr) item->setExpanded(true);
}

void WorkbenchWindow::openTreeItem(QTreeWidgetItem* item, int) {
    if (item->data(0, DirectoryRole).toBool() || workspaceRoot_.isEmpty()) return;
    activePath_ = item->data(0, RelativePathRole).toString();
    const auto response = core_.execute(
        "file.read",
        objectPayload(QJsonObject{{"root", workspaceRoot_}, {"path", activePath_}}).toStdString());
    const auto object = responseObject(QByteArray::fromStdString(response.json));
    if (!responseSucceeded(object)) { showCoreError(QByteArray::fromStdString(response.json)); return; }
    editor_->setPlainText(object.value("data").toObject().value("text").toString());
    statusBar()->showMessage(activePath_);
}

void WorkbenchWindow::searchWorkspace() {
    if (workspaceRoot_.isEmpty() || searchField_->text().trimmed().isEmpty()) return;
    const auto response = core_.execute(
        "workspace.search",
        objectPayload(QJsonObject{{"root", workspaceRoot_}, {"query", searchField_->text()}}).toStdString());
    const auto object = responseObject(QByteArray::fromStdString(response.json));
    if (!responseSucceeded(object)) { showCoreError(QByteArray::fromStdString(response.json)); return; }
    results_->clear();
    for (const auto& value : object.value("data").toObject().value("matches").toArray()) {
        const auto match = value.toObject();
        auto* result = new QListWidgetItem(QString("%1:%2  %3")
            .arg(match.value("path").toString())
            .arg(match.value("line").toInt())
            .arg(match.value("preview").toString()), results_);
        result->setData(RelativePathRole, match.value("path").toString());
    }
    results_->setVisible(results_->count() > 0);
    statusBar()->showMessage(QString("%1 search results").arg(results_->count()));
}

void WorkbenchWindow::saveDocument() {
    if (workspaceRoot_.isEmpty() || activePath_.isEmpty()) return;
    const auto response = core_.execute(
        "file.write",
        objectPayload(QJsonObject{{"root", workspaceRoot_}, {"path", activePath_}, {"text", editor_->toPlainText()}}).toStdString());
    const auto object = responseObject(QByteArray::fromStdString(response.json));
    if (!responseSucceeded(object)) { showCoreError(QByteArray::fromStdString(response.json)); return; }
    statusBar()->showMessage(QString("Saved %1").arg(activePath_), 3000);
}

void WorkbenchWindow::showCoreError(const QByteArray& response) {
    statusBar()->showMessage(errorMessage(responseObject(response)), 5000);
}

QString WorkbenchWindow::selectedRelativePath() const {
    const auto items = tree_->selectedItems();
    return items.isEmpty() ? QString{} : items.first()->data(0, RelativePathRole).toString();
}

QByteArray WorkbenchWindow::objectPayload(const QJsonObject& object) const {
    return QJsonDocument(object).toJson(QJsonDocument::Compact);
}

} // namespace lithe::windows
