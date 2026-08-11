#include "workbench_icons.h"

#include <QApplication>

#include <cassert>

int main(int argc, char* argv[]) {
    QApplication application(argc, argv);

    assert(!lithe::windows::workbenchIconForPath(QStringLiteral("src"), true).isNull());
    assert(!lithe::windows::workbenchIconForPath(QStringLiteral("src/main/java"), true).isNull());
    assert(!lithe::windows::workbenchIconForPath(QStringLiteral("README.md"), false).isNull());
    assert(!lithe::windows::workbenchIconForPath(QStringLiteral("Package.swift"), false).isNull());
    assert(!lithe::windows::workbenchIconForPath(QStringLiteral("unknown.lithe"), false).isNull());
    assert(!lithe::windows::workbenchActionIcon(QStringLiteral("actions/refresh.svg")).isNull());
    assert(!lithe::windows::workbenchActionIcon(QStringLiteral("actions/moreVertical.svg")).isNull());
    assert(!lithe::windows::workbenchActionIcon(
        QStringLiteral("toolwindows/toolWindowDebugger.svg")).isNull());
    assert(!lithe::windows::workbenchActionIcon(
        QStringLiteral("toolwindows/toolWindowProblems.svg")).isNull());
    assert(!lithe::windows::workbenchActionIcon(
        QStringLiteral("maven/toolWindowMaven.svg")).isNull());
    return 0;
}
