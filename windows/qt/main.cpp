#include "workbench_window.h"

#include "win32_directory_watcher.h"

#include <QApplication>

int main(int argc, char* argv[]) {
    QApplication application(argc, argv);
    lithe::windows::WorkbenchWindow window(
        std::make_unique<lithe::windows::Win32DirectoryChangeSource>());
    window.show();
    return application.exec();
}
