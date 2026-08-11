#include "workbench_icons.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QIODevice>
#include <QPainter>
#include <QPainterPath>
#include <QStringList>
#include <QSvgRenderer>
#include <QToolButton>

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

namespace lithe::windows::ui {
namespace {

QString resolveResourcesRoot() {
#ifdef LITHE_RESOURCES_DIR
    const QString configured = QString::fromUtf8(LITHE_RESOURCES_DIR);
    if (QDir(configured).exists()) return configured;
#endif
    QDir dir(QCoreApplication::applicationDirPath());
    for (int i = 0; i < 8; ++i) {
        if (dir.exists(QStringLiteral("Resources/IDEAIcons"))) {
            return dir.filePath(QStringLiteral("Resources"));
        }
        if (!dir.cdUp()) break;
    }
    return {};
}

QByteArray tintedSvg(const QByteArray& source, const QColor& tint) {
    if (!tint.isValid() || tint.alpha() == 0) return source;
    const auto hex = QStringLiteral("#%1%2%3")
                         .arg(tint.red(), 2, 16, QLatin1Char('0'))
                         .arg(tint.green(), 2, 16, QLatin1Char('0'))
                         .arg(tint.blue(), 2, 16, QLatin1Char('0'))
                         .toUpper();
    QByteArray result = source;
    result.replace("#CED0D6", hex.toUtf8());
    result.replace("#ced0d6", hex.toUtf8());
    return result;
}

QPixmap renderSvgFile(const QString& absolutePath, int size, const QColor& tint) {
    QFile file(absolutePath);
    if (!file.open(QIODevice::ReadOnly)) return {};
    const auto data = tintedSvg(file.readAll(), tint);
    QSvgRenderer renderer(data);
    if (!renderer.isValid()) return {};
    QPixmap pixmap(size, size);
    pixmap.fill(Qt::transparent);
    QPainter painter(&pixmap);
    painter.setRenderHint(QPainter::Antialiasing, true);
    renderer.render(&painter, QRectF(0, 0, size, size));
    return pixmap;
}

} // namespace

QString IdeaIcons::resourcesRoot() {
    static const QString root = resolveResourcesRoot();
    return root;
}

QPixmap IdeaIcons::pixmap(const QString& relativePath, int size, const QColor& tint) {
    const auto root = resourcesRoot();
    if (root.isEmpty() || relativePath.isEmpty()) return {};
    const auto path = QDir(root).filePath(QStringLiteral("IDEAIcons/") + relativePath);
    return renderSvgFile(path, size, tint);
}

QIcon IdeaIcons::icon(const QString& relativePath, int size, const QColor& tint) {
    const auto pix = pixmap(relativePath, size, tint);
    return pix.isNull() ? QIcon() : QIcon(pix);
}

void IdeaIcons::applyToToolButton(QToolButton* button,
                                  const QString& relativePath,
                                  int size,
                                  const QColor& tint) {
    if (button == nullptr) return;
    const auto icon = IdeaIcons::icon(relativePath, size, tint);
    if (icon.isNull()) return;
    button->setIcon(icon);
    button->setIconSize(QSize(size, size));
    button->setText({});
    button->setToolButtonStyle(Qt::ToolButtonIconOnly);
}

QIcon drawnIcon(const QString& kind, int size, const QColor& color) {
    const QColor ink = color.isValid() ? color : QColor(0x9B, 0xA1, 0xAA);
    QPixmap pixmap(size, size);
    pixmap.fill(Qt::transparent);
    QPainter painter(&pixmap);
    painter.setRenderHint(QPainter::Antialiasing, true);
    QPen pen(ink, std::max(1.2, size / 12.0), Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin);
    painter.setPen(pen);
    painter.setBrush(Qt::NoBrush);
    const qreal s = size;

    if (kind == QLatin1String("discard") || kind == QLatin1String("uturn")) {
        QPainterPath path;
        path.moveTo(s * 0.28, s * 0.42);
        path.cubicTo(s * 0.28, s * 0.18, s * 0.72, s * 0.18, s * 0.72, s * 0.48);
        painter.drawPath(path);
        painter.drawLine(QPointF(s * 0.28, s * 0.42), QPointF(s * 0.18, s * 0.30));
        painter.drawLine(QPointF(s * 0.28, s * 0.42), QPointF(s * 0.40, s * 0.30));
        painter.drawLine(QPointF(s * 0.72, s * 0.48), QPointF(s * 0.72, s * 0.78));
    } else if (kind == QLatin1String("stage") || kind == QLatin1String("download")) {
        painter.drawLine(QPointF(s * 0.50, s * 0.18), QPointF(s * 0.50, s * 0.62));
        painter.drawLine(QPointF(s * 0.32, s * 0.46), QPointF(s * 0.50, s * 0.64));
        painter.drawLine(QPointF(s * 0.68, s * 0.46), QPointF(s * 0.50, s * 0.64));
        painter.drawLine(QPointF(s * 0.22, s * 0.78), QPointF(s * 0.78, s * 0.78));
    } else if (kind == QLatin1String("eye") || kind == QLatin1String("preview")) {
        QPainterPath eye;
        eye.moveTo(s * 0.14, s * 0.50);
        eye.cubicTo(s * 0.30, s * 0.28, s * 0.70, s * 0.28, s * 0.86, s * 0.50);
        eye.cubicTo(s * 0.70, s * 0.72, s * 0.30, s * 0.72, s * 0.14, s * 0.50);
        painter.drawPath(eye);
        painter.setBrush(ink);
        painter.drawEllipse(QPointF(s * 0.50, s * 0.50), s * 0.10, s * 0.10);
    } else if (kind == QLatin1String("ai") || kind == QLatin1String("wand")) {
        painter.drawLine(QPointF(s * 0.28, s * 0.72), QPointF(s * 0.68, s * 0.26));
        painter.drawLine(QPointF(s * 0.62, s * 0.20), QPointF(s * 0.74, s * 0.32));
        painter.drawLine(QPointF(s * 0.72, s * 0.18), QPointF(s * 0.78, s * 0.28));
        painter.drawLine(QPointF(s * 0.40, s * 0.22), QPointF(s * 0.40, s * 0.34));
        painter.drawLine(QPointF(s * 0.34, s * 0.28), QPointF(s * 0.46, s * 0.28));
    } else if (kind == QLatin1String("checkmark") || kind == QLatin1String("clean")) {
        // macOS ChangesSidebarView: Image(systemName: "checkmark.circle") in success green.
        painter.setPen(QPen(ink, std::max(1.4, size / 11.0), Qt::SolidLine, Qt::RoundCap,
                            Qt::RoundJoin));
        painter.drawEllipse(QRectF(s * 0.12, s * 0.12, s * 0.76, s * 0.76));
        QPainterPath check;
        check.moveTo(s * 0.30, s * 0.52);
        check.lineTo(s * 0.44, s * 0.66);
        check.lineTo(s * 0.70, s * 0.36);
        painter.drawPath(check);
    } else if (kind == QLatin1String("up")) {
        painter.drawLine(QPointF(s * 0.50, s * 0.72), QPointF(s * 0.50, s * 0.28));
        painter.drawLine(QPointF(s * 0.32, s * 0.44), QPointF(s * 0.50, s * 0.26));
        painter.drawLine(QPointF(s * 0.68, s * 0.44), QPointF(s * 0.50, s * 0.26));
    } else if (kind == QLatin1String("down")) {
        painter.drawLine(QPointF(s * 0.50, s * 0.28), QPointF(s * 0.50, s * 0.72));
        painter.drawLine(QPointF(s * 0.32, s * 0.56), QPointF(s * 0.50, s * 0.74));
        painter.drawLine(QPointF(s * 0.68, s * 0.56), QPointF(s * 0.50, s * 0.74));
    } else if (kind == QLatin1String("close") || kind == QLatin1String("xmark")) {
        painter.drawLine(QPointF(s * 0.28, s * 0.28), QPointF(s * 0.72, s * 0.72));
        painter.drawLine(QPointF(s * 0.72, s * 0.28), QPointF(s * 0.28, s * 0.72));
    } else if (kind == QLatin1String("plus")) {
        painter.drawLine(QPointF(s * 0.50, s * 0.24), QPointF(s * 0.50, s * 0.76));
        painter.drawLine(QPointF(s * 0.24, s * 0.50), QPointF(s * 0.76, s * 0.50));
    }

    return QIcon(pixmap);
}

} // namespace lithe::windows::ui
