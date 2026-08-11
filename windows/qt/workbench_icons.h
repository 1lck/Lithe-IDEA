#pragma once

#include <QIcon>
#include <QString>

namespace lithe::windows {

QIcon workbenchIconForPath(const QString& relativePath, bool isDirectory);
QIcon workbenchActionIcon(const QString& resourceName);

} // namespace lithe::windows
