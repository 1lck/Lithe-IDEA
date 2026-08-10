#pragma once

#include "git_workflow_types.h"
#include "git_workflow_ui.h"

#include <QString>
#include <QStringList>
#include <QWidget>

#include <optional>
#include <utility>

namespace lithe::windows {

struct GitCheckoutDialogResult {
    app::GitCheckoutDialogDecision decision = app::GitCheckoutDialogDecision::Cancel;
    QString selectedPath;
};

struct GitIntegrationDialogResult {
    app::GitIntegrationDialogDecision decision = app::GitIntegrationDialogDecision::Cancel;
    QString selectedPath;
};

struct GitPullDialogResult {
    app::GitPullDialogDecision decision = app::GitPullDialogDecision::Cancel;
};

GitCheckoutDialogResult showGitCheckoutConflictDialog(
    QWidget* parent,
    const app::GitCheckoutConflictRequest& request);

GitIntegrationDialogResult showGitIntegrationConflictDialog(
    QWidget* parent,
    const app::GitIntegrationConflictRequest& request);

GitPullDialogResult showGitPullStrategyDialog(
    QWidget* parent,
    const app::GitPullStrategyRequest& request);

bool confirmDestructiveGitAction(QWidget* parent,
                                 const QString& title,
                                 const QString& message);

} // namespace lithe::windows
