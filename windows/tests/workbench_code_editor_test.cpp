#include "workbench_code_editor.h"

#include <QApplication>
#include <QTextBlock>
#include <QTextCursor>
#include <QTextDocument>

namespace {

}

int main(int argc, char* argv[]) {
    QApplication application(argc, argv);
    lithe::windows::WorkbenchCodeEditor editor;
    editor.resize(900, 400);
    editor.setPlainText(QStringLiteral(
        "import org.example.Service;\n"
        "public class AppTest {\n"
        "    void run() {}\n"
        "}\n"));
    editor.show();
    application.processEvents();

    const auto block = editor.document()->findBlockByNumber(1);
    const auto sourceCursor = QTextCursor(block);
    const auto sourceY = editor.cursorRect(sourceCursor).y();
    const auto baseViewportLeft = editor.viewport()->geometry().left();

    editor.setCodeVision({{1, QStringLiteral("1 usages  AppTest")}});
    editor.setImplementationMarkers({{1, QStringLiteral("0 implementations (down)")}});
    application.processEvents();

    assert(block.blockFormat().topMargin() == 0.0);
    assert(editor.viewport()->geometry().left() > baseViewportLeft);
    assert(editor.cursorRect(sourceCursor).y() == sourceY);
    return 0;
}
