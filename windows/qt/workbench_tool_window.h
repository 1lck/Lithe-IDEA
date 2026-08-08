#pragma once

#include "workbench_ui_state.h"

#include <QWidget>

#include <array>

class QLabel;
class QPushButton;
class QStackedWidget;
class QTabBar;

namespace lithe::windows {

class WorkbenchToolWindow final : public QWidget {
    Q_OBJECT

public:
    explicit WorkbenchToolWindow(QWidget* parent = nullptr);

    BottomToolKind kind() const;
    void setKind(BottomToolKind kind);
    QTabBar* toolSelector() const;
    QStackedWidget* pages() const;
    QWidget* page(BottomToolKind kind) const;
    void setPanel(BottomToolKind kind, QWidget* panel);

signals:
    void toolChanged(BottomToolKind kind);
    void hideRequested();

private:
    static int indexFor(BottomToolKind kind);
    static QString titleFor(BottomToolKind kind);

    BottomToolKind kind_ = BottomToolKind::Terminal;
    QLabel* title_ = nullptr;
    QTabBar* toolSelector_ = nullptr;
    QStackedWidget* pages_ = nullptr;
    std::array<QWidget*, 6> pageWidgets_{};
    std::array<QLabel*, 6> placeholders_{};
};

}
