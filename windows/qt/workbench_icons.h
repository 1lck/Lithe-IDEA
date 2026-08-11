#pragma once

#include <QIcon>
#include <QPixmap>
#include <QString>

class QColor;
class QToolButton;

namespace lithe::windows {

QIcon workbenchIconForPath(const QString& relativePath, bool isDirectory);
QIcon workbenchActionIcon(const QString& resourceName);

} // namespace lithe::windows

namespace lithe::windows::ui {

/// Loads IntelliJ Platform SVGs from Resources/IDEAIcons (same catalog as macOS LitheIcons).
class IdeaIcons {
public:
    static QString resourcesRoot();

    /// Relative path under IDEAIcons, e.g. "toolwindows/toolWindowCommit.svg".
    static QIcon icon(const QString& relativePath,
                      int size = 16,
                      const QColor& tint = QColor());

    static QPixmap pixmap(const QString& relativePath,
                          int size = 16,
                          const QColor& tint = QColor());

    static void applyToToolButton(QToolButton* button,
                                  const QString& relativePath,
                                  int size = 16,
                                  const QColor& tint = QColor());
};

/// Drawn fallbacks for toolbar glyphs that macOS keeps as SF Symbols
/// (no direct IDEA asset in the imported set).
QIcon drawnIcon(const QString& kind, int size = 16, const QColor& color = QColor());

} // namespace lithe::windows::ui
