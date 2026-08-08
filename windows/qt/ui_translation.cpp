#include "ui_translation.h"

#include "app_persistence.h"

#include <QFile>
#include <QHash>
#include <QLocale>
#include <QXmlStreamReader>

#include <utility>

namespace lithe::windows {
namespace {

constexpr char kSimplifiedChinese[] = "zh_CN";
QHash<QString, QString> translations;

QString translate(const QString& source) {
    return translations.value(source, source);
}

}

std::string effectiveUiLanguage(const std::string& configuredLanguage) {
    return app::effectiveUiLanguage(
        configuredLanguage,
        QLocale::system().language() == QLocale::Chinese);
}

bool installUiTranslator(const std::string& language) {
    translations.clear();
    if (language == "en") return true;
    if (language != kSimplifiedChinese) return false;
    QFile file(QStringLiteral(":/i18n/lithe_zh_CN.ts"));
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) return false;
    QXmlStreamReader xml(&file);
    QHash<QString, QString> loaded;
    while (!xml.atEnd()) {
        xml.readNext();
        if (!xml.isStartElement() || xml.name() != QStringLiteral("message")) continue;
        QString source;
        QString translation;
        while (!(xml.isEndElement() && xml.name() == QStringLiteral("message")) &&
               !xml.atEnd()) {
            xml.readNext();
            if (!xml.isStartElement()) continue;
            if (xml.name() == QStringLiteral("source")) source = xml.readElementText();
            if (xml.name() == QStringLiteral("translation")) {
                const auto type = xml.attributes().value(QStringLiteral("type"));
                if (type == QStringLiteral("unfinished") ||
                    type == QStringLiteral("vanished") ||
                    type == QStringLiteral("obsolete")) {
                    xml.skipCurrentElement();
                    continue;
                }
                translation = xml.readElementText();
            }
        }
        if (!source.isEmpty() && !translation.isEmpty()) loaded.insert(source, translation);
    }
    if (xml.hasError() || !loaded.contains(QStringLiteral("Open")) ||
        !loaded.contains(QStringLiteral("Settings"))) {
        return false;
    }
    translations = std::move(loaded);
    return true;
}

QString uiText(const QString& source) {
    return translate(source);
}

}
