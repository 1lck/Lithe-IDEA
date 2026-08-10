#include "git_workflow_dialogs.h"

#include <QAbstractItemView>
#include <QDialog>
#include <QDialogButtonBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QListWidget>
#include <QMessageBox>
#include <QPushButton>
#include <QVBoxLayout>

namespace lithe::windows {
namespace {

QStringList toQtPaths(const std::vector<std::string>& paths) {
    QStringList result;
    result.reserve(static_cast<int>(paths.size()));
    for (const auto& path : paths) {
        result.push_back(QString::fromUtf8(path.data(), static_cast<int>(path.size())));
    }
    return result;
}

QListWidget* makePathList(QWidget* parent, const QStringList& paths) {
    auto* list = new QListWidget(parent);
    for (const auto& path : paths) list->addItem(path);
    list->setSelectionMode(QAbstractItemView::SingleSelection);
    list->setMinimumHeight(140);
    return list;
}

} // namespace

GitCheckoutDialogResult showGitCheckoutConflictDialog(
    QWidget* parent,
    const app::GitCheckoutConflictRequest& request) {
    QDialog dialog(parent);
    dialog.setWindowTitle(QStringLiteral("Checkout blocked"));
    auto* layout = new QVBoxLayout(&dialog);
    auto* summary = new QLabel(
        QStringLiteral("Local changes would be overwritten by checkout of %1.")
            .arg(QString::fromStdString(request.shortName)),
        &dialog);
    summary->setWordWrap(true);
    layout->addWidget(summary);

    if (!request.dirtyDocumentPaths.empty()) {
        auto* dirty = new QLabel(
            QStringLiteral("Unsaved documents must be saved or discarded first."),
            &dialog);
        dirty->setWordWrap(true);
        layout->addWidget(dirty);
    }

    auto* list = makePathList(&dialog, toQtPaths(request.blockingPaths));
    layout->addWidget(list);

    auto* buttons = new QDialogButtonBox(&dialog);
    auto* smart = buttons->addButton(QStringLiteral("Smart Checkout"),
                                     QDialogButtonBox::AcceptRole);
    auto* force = buttons->addButton(QStringLiteral("Force Checkout"),
                                     QDialogButtonBox::DestructiveRole);
    auto* openDiff = buttons->addButton(QStringLiteral("Open Diff"),
                                        QDialogButtonBox::ActionRole);
    auto* discard = buttons->addButton(QStringLiteral("Discard File and Retry"),
                                       QDialogButtonBox::ActionRole);
    buttons->addButton(QDialogButtonBox::Cancel);
    layout->addWidget(buttons);

    GitCheckoutDialogResult result;
    QObject::connect(smart, &QPushButton::clicked, &dialog, [&] {
        result.decision = app::GitCheckoutDialogDecision::Smart;
        dialog.accept();
    });
    QObject::connect(force, &QPushButton::clicked, &dialog, [&] {
        if (!confirmDestructiveGitAction(
                &dialog,
                QStringLiteral("Force Checkout"),
                QStringLiteral("Discard local changes that block checkout?"))) {
            return;
        }
        result.decision = app::GitCheckoutDialogDecision::Force;
        dialog.accept();
    });
    QObject::connect(openDiff, &QPushButton::clicked, &dialog, [&] {
        const auto* item = list->currentItem();
        if (item == nullptr) return;
        result.decision = app::GitCheckoutDialogDecision::OpenDiff;
        result.selectedPath = item->text();
        dialog.accept();
    });
    QObject::connect(discard, &QPushButton::clicked, &dialog, [&] {
        const auto* item = list->currentItem();
        if (item == nullptr) return;
        if (!confirmDestructiveGitAction(
                &dialog,
                QStringLiteral("Discard File"),
                QStringLiteral("Discard local changes in the selected file and retry?"))) {
            return;
        }
        result.decision = app::GitCheckoutDialogDecision::DiscardAndRetry;
        result.selectedPath = item->text();
        dialog.accept();
    });
    QObject::connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);

    if (dialog.exec() != QDialog::Accepted) {
        result.decision = app::GitCheckoutDialogDecision::Cancel;
        result.selectedPath.clear();
    }
    return result;
}

GitIntegrationDialogResult showGitIntegrationConflictDialog(
    QWidget* parent,
    const app::GitIntegrationConflictRequest& request) {
    QDialog dialog(parent);
    dialog.setWindowTitle(QStringLiteral("%1 blocked")
                              .arg(QString::fromUtf8(
                                  app::integrationOperationTitle(request.operation))));
    auto* layout = new QVBoxLayout(&dialog);
    const auto summaryText = request.blocksEntirely
        ? QStringLiteral("%1 onto %2 requires a clean working tree.")
              .arg(QString::fromUtf8(app::integrationOperationTitle(request.operation)))
              .arg(QString::fromStdString(request.displayName))
        : QStringLiteral("%1 of %2 overlaps local changes.")
              .arg(QString::fromUtf8(app::integrationOperationTitle(request.operation)))
              .arg(QString::fromStdString(request.displayName));
    auto* summary = new QLabel(summaryText, &dialog);
    summary->setWordWrap(true);
    layout->addWidget(summary);

    auto* list = makePathList(&dialog, toQtPaths(request.blockingPaths));
    layout->addWidget(list);

    auto* buttons = new QDialogButtonBox(&dialog);
    auto* save = buttons->addButton(QStringLiteral("Save Changes and Continue"),
                                    QDialogButtonBox::AcceptRole);
    auto* openDiff = buttons->addButton(QStringLiteral("Open Diff"),
                                        QDialogButtonBox::ActionRole);
    auto* discard = buttons->addButton(QStringLiteral("Discard File and Retry"),
                                       QDialogButtonBox::ActionRole);
    buttons->addButton(QDialogButtonBox::Cancel);
    layout->addWidget(buttons);

    GitIntegrationDialogResult result;
    QObject::connect(save, &QPushButton::clicked, &dialog, [&] {
        result.decision = app::GitIntegrationDialogDecision::SaveAndContinue;
        dialog.accept();
    });
    QObject::connect(openDiff, &QPushButton::clicked, &dialog, [&] {
        const auto* item = list->currentItem();
        if (item == nullptr) return;
        result.decision = app::GitIntegrationDialogDecision::OpenDiff;
        result.selectedPath = item->text();
        dialog.accept();
    });
    QObject::connect(discard, &QPushButton::clicked, &dialog, [&] {
        const auto* item = list->currentItem();
        if (item == nullptr) return;
        if (!confirmDestructiveGitAction(
                &dialog,
                QStringLiteral("Discard File"),
                QStringLiteral("Discard local changes in the selected file and retry?"))) {
            return;
        }
        result.decision = app::GitIntegrationDialogDecision::DiscardAndRetry;
        result.selectedPath = item->text();
        dialog.accept();
    });
    QObject::connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);

    if (dialog.exec() != QDialog::Accepted) {
        result.decision = app::GitIntegrationDialogDecision::Cancel;
        result.selectedPath.clear();
    }
    return result;
}

GitPullDialogResult showGitPullStrategyDialog(
    QWidget* parent,
    const app::GitPullStrategyRequest& request) {
    QDialog dialog(parent);
    dialog.setWindowTitle(QStringLiteral("Pull diverged"));
    auto* layout = new QVBoxLayout(&dialog);
    auto* summary = new QLabel(
        QStringLiteral("Branch and %1 have diverged (ahead %2, behind %3). Choose how to integrate.")
            .arg(QString::fromStdString(request.upstream))
            .arg(static_cast<qulonglong>(request.ahead))
            .arg(static_cast<qulonglong>(request.behind)),
        &dialog);
    summary->setWordWrap(true);
    layout->addWidget(summary);

    auto* buttons = new QDialogButtonBox(&dialog);
    auto* ffOnly = buttons->addButton(QStringLiteral("Fast-forward only"),
                                      QDialogButtonBox::ActionRole);
    auto* merge = buttons->addButton(QStringLiteral("Merge"),
                                     QDialogButtonBox::AcceptRole);
    auto* rebase = buttons->addButton(QStringLiteral("Rebase"),
                                      QDialogButtonBox::AcceptRole);
    buttons->addButton(QDialogButtonBox::Cancel);
    layout->addWidget(buttons);

    GitPullDialogResult result;
    QObject::connect(ffOnly, &QPushButton::clicked, &dialog, [&] {
        result.decision = app::GitPullDialogDecision::FfOnly;
        dialog.accept();
    });
    QObject::connect(merge, &QPushButton::clicked, &dialog, [&] {
        result.decision = app::GitPullDialogDecision::Merge;
        dialog.accept();
    });
    QObject::connect(rebase, &QPushButton::clicked, &dialog, [&] {
        result.decision = app::GitPullDialogDecision::Rebase;
        dialog.accept();
    });
    QObject::connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);

    if (dialog.exec() != QDialog::Accepted) {
        result.decision = app::GitPullDialogDecision::Cancel;
    }
    return result;
}

bool confirmDestructiveGitAction(QWidget* parent,
                                 const QString& title,
                                 const QString& message) {
    return QMessageBox::warning(parent, title, message,
                                QMessageBox::Ok | QMessageBox::Cancel,
                                QMessageBox::Cancel) == QMessageBox::Ok;
}

} // namespace lithe::windows
