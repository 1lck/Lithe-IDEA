#pragma once

#include "core_client.h"
#include "ports.h"

#include <QJsonObject>
#include <QMainWindow>

#include <memory>

class QLineEdit;
class QListWidget;
class QPlainTextEdit;
class QTreeWidget;
class QTreeWidgetItem;

namespace lithe::windows {

class WorkbenchWindow final : public QMainWindow {
    Q_OBJECT

public:
    explicit WorkbenchWindow(std::unique_ptr<DirectoryChangeSource> watcher,
                             QWidget* parent = nullptr);
    ~WorkbenchWindow() override;

private slots:
    void chooseWorkspace();
    void refreshWorkspace();
    void openTreeItem(QTreeWidgetItem* item, int column);
    void searchWorkspace();
    void saveDocument();

private:
    void buildActions();
    void loadSnapshot();
    void appendTreeNode(QTreeWidgetItem* parent, const QJsonObject& node);
    void showCoreError(const QByteArray& response);
    QString selectedRelativePath() const;
    QByteArray objectPayload(const QJsonObject& object) const;

    CoreClient core_;
    std::unique_ptr<DirectoryChangeSource> watcher_;
    QString workspaceRoot_;
    QString activePath_;
    QTreeWidget* tree_ = nullptr;
    QPlainTextEdit* editor_ = nullptr;
    QLineEdit* searchField_ = nullptr;
    QListWidget* results_ = nullptr;
};

} // namespace lithe::windows
