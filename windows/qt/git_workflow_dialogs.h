#pragma once

#include "git_workflow_types.h"
#include "git_workflow_ui.h"

#include <QString>
#include <QStringList>
#include <QWidget>

#include <optional>
#include <utility>
#include <vector>

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

/// macOS-style reference picker used for Merge / Rebase / Switch / Push.
std::optional<int> showGitReferencePickerDialog(
    QWidget* parent,
    const QString& title,
    const QString& prompt,
    const QStringList& choices,
    int currentIndex = 0);

std::optional<QString> showGitTextInputDialog(
    QWidget* parent,
    const QString& title,
    const QString& prompt,
    const QString& initialValue = {});

bool confirmDestructiveGitAction(QWidget* parent,
                                 const QString& title,
                                 const QString& message);

} // namespace lithe::windows
