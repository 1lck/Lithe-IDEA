#include "workbench_window.h"

#include "app_persistence.h"
#include "win32_directory_watcher.h"
#include "win32_key_value_store.h"
#include "ui_translation.h"
#include "ui_theme.h"
#include "windows_chrome.h"

#include <QApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>
#include <QTextStream>

#include <cstdio>
#include <string_view>

#ifdef _WIN32
#include <windows.h>
#endif

namespace {

QFile* messageLogFile = nullptr;
bool messageConsoleEnabled = false;

bool hasArgument(int argc, char* argv[], const char* value) {
    for (int index = 1; index < argc; ++index) {
        if (std::string_view(argv[index]) == value) return true;
    }
    return false;
}

void showConsole() {
#ifdef _WIN32
    if (!AttachConsole(ATTACH_PARENT_PROCESS)) AllocConsole();
    FILE* stream = nullptr;
    freopen_s(&stream, "CONOUT$", "w", stdout);
    freopen_s(&stream, "CONOUT$", "w", stderr);
    freopen_s(&stream, "CONIN$", "r", stdin);
#endif
}

void handleQtMessage(QtMsgType type,
                     const QMessageLogContext&,
                     const QString& message) {
    const auto line = QStringLiteral("%1 [%2] %3\n")
        .arg(QDateTime::currentDateTime().toString(Qt::ISODate))
        .arg(static_cast<int>(type))
        .arg(message);
    if (messageLogFile != nullptr && messageLogFile->isOpen()) {
        QTextStream stream(messageLogFile);
        stream << line;
        stream.flush();
    }
    if (messageConsoleEnabled) {
        fprintf(stderr, "%s", line.toLocal8Bit().constData());
    }
}

}

int main(int argc, char* argv[]) {
    QApplication application(argc, argv);
    lithe::windows::applyUiTheme(application);
    QCoreApplication::setApplicationName(QStringLiteral("Lithe"));
    QCoreApplication::setOrganizationName(QStringLiteral("Lithe"));
    lithe::windows::Win32KeyValueStore keyValueStore;
    lithe::windows::app::AppSettingsStore settingsStore(keyValueStore);
    const auto settings = settingsStore.load();
    const auto language = lithe::windows::effectiveUiLanguage(settings.uiLanguage);
    if (!lithe::windows::installUiTranslator(language)) {
        qWarning() << "Unable to load UI translation resource for" << QString::fromStdString(language);
    }
    const bool consoleEnabled = hasArgument(argc, argv, "--console");
    if (consoleEnabled) showConsole();

    auto dataRoot = QString::fromStdString(settings.dataDirectory).trimmed();
    if (dataRoot.isEmpty()) {
        dataRoot = QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation);
    }
    QFile logFile(QDir(dataRoot).filePath(QStringLiteral("logs/lithe.log")));
    QDir().mkpath(QFileInfo(logFile).absolutePath());
    logFile.open(QIODevice::Append | QIODevice::Text);
    messageLogFile = &logFile;
    messageConsoleEnabled = consoleEnabled;
    qInstallMessageHandler(handleQtMessage);
    qInfo() << "Lithe starting";
    lithe::windows::WorkbenchWindow window(
        std::make_unique<lithe::windows::Win32DirectoryChangeSource>());
    lithe::windows::applyWindowsWindowChrome(window);
    window.show();
    return application.exec();
}
