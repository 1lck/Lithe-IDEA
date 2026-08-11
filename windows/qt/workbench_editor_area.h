#pragma once

#include <QWidget>

class QLabel;
class QListWidget;
class QListWidgetItem;
class QLineEdit;
class QTabBar;
class QStackedWidget;

namespace lithe::windows {

class WorkbenchCodeEditor;

class WorkbenchEditorArea final : public QWidget {
    Q_OBJECT

public:
    explicit WorkbenchEditorArea(QWidget* parent = nullptr);

    WorkbenchCodeEditor* editor() const;
    QTabBar* editorTabs() const;
    QWidget* findBar() const;
    QLineEdit* findField() const;
    QLabel* findStatus() const;
    QListWidget* searchResults() const;
    QListWidget* javaNavigationResults() const;
    QListWidget* diagnostics() const;
    QLabel* emptyState() const;

    void setEmptyStateVisible(bool visible);

signals:
    void tabChanged(int index);
    void tabCloseRequested(int index);
    void findPreviousRequested();
    void findNextRequested();
    void findBarCloseRequested();
    void searchResultActivated(QListWidgetItem* item);
    void javaNavigationResultActivated(QListWidgetItem* item);
    void diagnosticActivated(QListWidgetItem* item);

private:
    QWidget* findBar_ = nullptr;
    QLineEdit* findField_ = nullptr;
    QLabel* findStatus_ = nullptr;
    QTabBar* editorTabs_ = nullptr;
    QStackedWidget* editorStack_ = nullptr;
    QLabel* emptyState_ = nullptr;
    WorkbenchCodeEditor* editor_ = nullptr;
    QListWidget* searchResults_ = nullptr;
    QListWidget* javaNavigationResults_ = nullptr;
    QListWidget* diagnostics_ = nullptr;
};

}
