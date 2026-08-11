#include "ui_translation.h"

#include <QCoreApplication>
#include <QString>

#include <cassert>

int main(int argc, char* argv[]) {
    QCoreApplication application(argc, argv);
    assert(lithe::windows::installUiTranslator("zh_CN"));
    assert(lithe::windows::uiText(QStringLiteral("Settings")) == QStringLiteral("设置"));
    assert(lithe::windows::uiText(QStringLiteral("Changes")) == QStringLiteral("更改"));
    assert(lithe::windows::uiText(QStringLiteral("Problems")) == QStringLiteral("问题"));
    assert(lithe::windows::uiText(QStringLiteral("Diff")) == QStringLiteral("差异"));
    assert(lithe::windows::uiText(QStringLiteral("No Maven project")) ==
           QStringLiteral("没有 Maven 项目"));
    assert(lithe::windows::uiText(QStringLiteral("%1 run configurations")) ==
           QStringLiteral("%1 个运行配置"));
    assert(lithe::windows::uiText(QStringLiteral("%1 code vision hints")) ==
           QStringLiteral("%1 个代码提示"));
    assert(lithe::windows::uiText(QStringLiteral("%1 fold regions")) ==
           QStringLiteral("%1 个折叠区域"));
    assert(lithe::windows::uiText(QStringLiteral("Missing stable key")) ==
           QStringLiteral("Missing stable key"));
    assert(lithe::windows::installUiTranslator("en"));
    assert(lithe::windows::uiText(QStringLiteral("Settings")) == QStringLiteral("Settings"));
    return 0;
}
