#pragma once

#include <QWidget>
#include <QString>

class QLabel;
class QListWidget;
class QListWidgetItem;
class QLineEdit;
class QPushButton;
class QTabBar;
class QStackedWidget;

namespace lithe::windows {

class WorkbenchCodeEditor;

class WorkbenchEditorArea final : public QWidget {
    Q_OBJECT

public:
    explicit WorkbenchEditorArea(QWidget* parent = nullptr);

    WorkbenchCodeEditor* editor() const;
    WorkbenchCodeEditor* ensureEditor(const QString& relativePath);
    WorkbenchCodeEditor* editorForPath(const QString& relativePath) const;
    WorkbenchCodeEditor* setActiveEditor(const QString& relativePath);
    void removeEditor(const QString& relativePath);
    void clearEditors();
    QTabBar* editorTabs() const;
    QWidget* findBar() const;
    QLineEdit* findField() const;
    QLabel* findStatus() const;
    QListWidget* searchResults() const;
    QListWidget* javaNavigationResults() const;
    QListWidget* diagnostics() const;
    QLabel* emptyState() const;

    void setEmptyStateVisible(bool visible);
    void showModifiedConflict(const QString& relativePath);
    void showDeletedConflict(const QString& relativePath);
    void showDocumentError(const QString& relativePath, const QString& message);
    void clearDocumentStatus(const QString& relativePath);

signals:
    void editorCreated(WorkbenchCodeEditor* editor);
    void tabChanged(int index);
    void tabCloseRequested(int index);
    void findPreviousRequested();
    void findNextRequested();
    void findBarCloseRequested();
    void searchResultActivated(QListWidgetItem* item);
    void javaNavigationResultActivated(QListWidgetItem* item);
    void diagnosticActivated(QListWidgetItem* item);
    void keepEditorVersionRequested(const QString& relativePath);
    void loadDiskVersionRequested(const QString& relativePath);
    void recreateDeletedFileRequested(const QString& relativePath);
    void closeDeletedFileRequested(const QString& relativePath);

private:
    QWidget* findBar_ = nullptr;
    QLineEdit* findField_ = nullptr;
    QLabel* findStatus_ = nullptr;
    QTabBar* editorTabs_ = nullptr;
    QStackedWidget* editorStack_ = nullptr;
    QWidget* statusBanner_ = nullptr;
    QLabel* statusBannerText_ = nullptr;
    QPushButton* statusPrimary_ = nullptr;
    QPushButton* statusSecondary_ = nullptr;
    QLabel* emptyState_ = nullptr;
    WorkbenchCodeEditor* editor_ = nullptr;
    QListWidget* searchResults_ = nullptr;
    QListWidget* javaNavigationResults_ = nullptr;
    QListWidget* diagnostics_ = nullptr;
};

}
