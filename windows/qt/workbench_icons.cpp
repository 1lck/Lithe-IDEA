#include "workbench_icons.h"

#include <QDir>
#include <QFileInfo>
#include <QHash>
#include <QStringList>

namespace lithe::windows {
namespace {

QIcon icon(const QString& relativeResourcePath) {
    return QIcon(QStringLiteral(":/icons/") + relativeResourcePath);
}

bool isSourceRoot(const QStringList& parts, int index) {
    if (index <= 0) return false;
    const auto parent = parts.at(index - 1).toLower();
    if (parent != QStringLiteral("main") && parent != QStringLiteral("test")) return false;
    const auto name = parts.at(index).toLower();
    static const QStringList roots{
        QStringLiteral("java"), QStringLiteral("kotlin"), QStringLiteral("scala"),
        QStringLiteral("groovy"), QStringLiteral("resources"), QStringLiteral("res"),
        QStringLiteral("webapp"), QStringLiteral("static"),
    };
    return roots.contains(name);
}

bool isInsideSourceRoot(const QStringList& parts) {
    for (int index = 0; index + 1 < parts.size(); ++index) {
        if (isSourceRoot(parts, index)) return true;
    }
    return false;
}

QString directoryIcon(const QString& relativePath) {
    const auto normalized = QDir::fromNativeSeparators(relativePath);
    const auto parts = normalized.split(u'/', Qt::SkipEmptyParts);
    const auto name = parts.isEmpty() ? QString{} : parts.constLast().toLower();
    static const QStringList excluded{
        QStringLiteral("target"), QStringLiteral("build"), QStringLiteral("out"),
        QStringLiteral("bin"), QStringLiteral("dist"), QStringLiteral("node_modules"),
        QStringLiteral(".gradle"), QStringLiteral(".idea"), QStringLiteral(".settings"),
    };
    if (excluded.contains(name)) return QStringLiteral("nodes/excludeRoot.svg");

    const auto index = parts.size() - 1;
    if (index >= 0 && isSourceRoot(parts, index)) {
        if (name == QStringLiteral("resources") || name == QStringLiteral("res") ||
            name == QStringLiteral("webapp") || name == QStringLiteral("static")) {
            return QStringLiteral("nodes/resourcesRoot.svg");
        }
        return QStringLiteral("nodes/sourceRoot.svg");
    }
    if (isInsideSourceRoot(parts)) return QStringLiteral("nodes/package.svg");
    return QStringLiteral("nodes/folder.svg");
}

QString fileIcon(const QString& relativePath) {
    const QFileInfo info(relativePath);
    const auto name = info.fileName().toLower();
    if (name == QStringLiteral("pom.xml")) return QStringLiteral("maven/mavenProject.svg");
    if (name == QStringLiteral(".gitignore") || name == QStringLiteral(".gitattributes") ||
        name == QStringLiteral(".dockerignore")) return QStringLiteral("fileTypes/properties.svg");
    if (name == QStringLiteral("dockerfile") || name.startsWith(QStringLiteral("dockerfile."))) {
        return QStringLiteral("fileTypes/docker.svg");
    }
    if (name == QStringLiteral(".editorconfig")) return QStringLiteral("fileTypes/editorConfig.svg");
    if (name == QStringLiteral(".env") || name.startsWith(QStringLiteral(".env."))) {
        return QStringLiteral("fileTypes/properties.svg");
    }
    if (name.endsWith(QStringLiteral(".gradle.kts"))) return QStringLiteral("fileTypes/gradle.svg");

    static const QHash<QString, QString> extensions{
        {QStringLiteral("java"), QStringLiteral("fileTypes/java.svg")},
        {QStringLiteral("class"), QStringLiteral("fileTypes/archive.svg")},
        {QStringLiteral("jar"), QStringLiteral("fileTypes/archive.svg")},
        {QStringLiteral("swift"), QStringLiteral("fileTypes/swiftLang.svg")},
        {QStringLiteral("kt"), QStringLiteral("fileTypes/kotlin.svg")},
        {QStringLiteral("kts"), QStringLiteral("fileTypes/kotlin.svg")},
        {QStringLiteral("rs"), QStringLiteral("fileTypes/rust.svg")},
        {QStringLiteral("go"), QStringLiteral("fileTypes/go.svg")},
        {QStringLiteral("py"), QStringLiteral("fileTypes/python.svg")},
        {QStringLiteral("rb"), QStringLiteral("fileTypes/ruby.svg")},
        {QStringLiteral("scala"), QStringLiteral("fileTypes/scala.svg")},
        {QStringLiteral("groovy"), QStringLiteral("fileTypes/groovy.svg")},
        {QStringLiteral("php"), QStringLiteral("fileTypes/php.svg")},
        {QStringLiteral("c"), QStringLiteral("fileTypes/c.svg")},
        {QStringLiteral("h"), QStringLiteral("fileTypes/h.svg")},
        {QStringLiteral("cpp"), QStringLiteral("fileTypes/cpp.svg")},
        {QStringLiteral("cc"), QStringLiteral("fileTypes/cpp.svg")},
        {QStringLiteral("hpp"), QStringLiteral("fileTypes/cpp.svg")},
        {QStringLiteral("cs"), QStringLiteral("fileTypes/csharp.svg")},
        {QStringLiteral("sh"), QStringLiteral("fileTypes/shell.svg")},
        {QStringLiteral("ps1"), QStringLiteral("fileTypes/shell.svg")},
        {QStringLiteral("js"), QStringLiteral("fileTypes/javaScript.svg")},
        {QStringLiteral("ts"), QStringLiteral("fileTypes/javaScript.svg")},
        {QStringLiteral("css"), QStringLiteral("fileTypes/css.svg")},
        {QStringLiteral("html"), QStringLiteral("fileTypes/html.svg")},
        {QStringLiteral("htm"), QStringLiteral("fileTypes/html.svg")},
        {QStringLiteral("gradle"), QStringLiteral("fileTypes/gradle.svg")},
        {QStringLiteral("xml"), QStringLiteral("fileTypes/xml.svg")},
        {QStringLiteral("properties"), QStringLiteral("fileTypes/properties.svg")},
        {QStringLiteral("yaml"), QStringLiteral("fileTypes/yaml.svg")},
        {QStringLiteral("yml"), QStringLiteral("fileTypes/yaml.svg")},
        {QStringLiteral("json"), QStringLiteral("fileTypes/json.svg")},
        {QStringLiteral("toml"), QStringLiteral("fileTypes/toml.svg")},
        {QStringLiteral("csv"), QStringLiteral("fileTypes/csv.svg")},
        {QStringLiteral("sql"), QStringLiteral("fileTypes/sql.svg")},
        {QStringLiteral("md"), QStringLiteral("fileTypes/markdown.svg")},
        {QStringLiteral("markdown"), QStringLiteral("fileTypes/markdown.svg")},
        {QStringLiteral("txt"), QStringLiteral("fileTypes/text.svg")},
        {QStringLiteral("png"), QStringLiteral("fileTypes/image.svg")},
        {QStringLiteral("jpg"), QStringLiteral("fileTypes/image.svg")},
        {QStringLiteral("jpeg"), QStringLiteral("fileTypes/image.svg")},
        {QStringLiteral("gif"), QStringLiteral("fileTypes/image.svg")},
        {QStringLiteral("svg"), QStringLiteral("fileTypes/image.svg")},
        {QStringLiteral("ico"), QStringLiteral("fileTypes/image.svg")},
        {QStringLiteral("zip"), QStringLiteral("fileTypes/archive.svg")},
    };
    const auto found = extensions.constFind(info.suffix().toLower());
    return found == extensions.cend() ? QStringLiteral("fileTypes/unknown.svg") : found.value();
}

} // namespace

QIcon workbenchIconForPath(const QString& relativePath, bool isDirectory) {
    return icon(isDirectory ? directoryIcon(relativePath) : fileIcon(relativePath));
}

QIcon workbenchActionIcon(const QString& resourceName) {
    return icon(resourceName);
}

} // namespace lithe::windows
