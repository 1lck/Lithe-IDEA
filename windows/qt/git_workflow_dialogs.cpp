#include "git_workflow_dialogs.h"

#include "workbench_ui_theme.h"

#include <QAbstractItemView>
#include <QDialog>
#include <QDialogButtonBox>
#include <QFrame>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QMessageBox>
#include <QPushButton>
#include <QVBoxLayout>

namespace lithe::windows {
namespace {

void applyDialogChrome(QDialog* dialog) {
    if (dialog == nullptr) return;
    dialog->setStyleSheet(ui::litheDialogStyleSheet());
    dialog->setMinimumWidth(420);
}

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
    list->setMinimumHeight(160);
    return list;
}

QLabel* makeTitle(QWidget* parent, const QString& text) {
    auto* label = new QLabel(text, parent);
    label->setProperty("dialogTitle", true);
    label->setWordWrap(true);
    return label;
}

QLabel* makeMeta(QWidget* parent, const QString& text) {
    auto* label = new QLabel(text, parent);
    label->setProperty("dialogMeta", true);
    label->setWordWrap(true);
    return label;
}

} // namespace

GitCheckoutDialogResult showGitCheckoutConflictDialog(
    QWidget* parent,
    const app::GitCheckoutConflictRequest& request) {
    QDialog dialog(parent);
    dialog.setWindowTitle(QStringLiteral("Checkout blocked"));
    applyDialogChrome(&dialog);
    auto* layout = new QVBoxLayout(&dialog);
    layout->setContentsMargins(18, 16, 18, 16);
    layout->setSpacing(12);
    layout->addWidget(makeTitle(
        &dialog,
        QStringLiteral("Local changes would be overwritten by checkout of %1.")
            .arg(QString::fromStdString(request.shortName))));

    if (!request.dirtyDocumentPaths.empty()) {
        layout->addWidget(makeMeta(
            &dialog,
            QStringLiteral("Unsaved documents must be saved or discarded first.")));
    }

    auto* list = makePathList(&dialog, toQtPaths(request.blockingPaths));
    layout->addWidget(list, 1);

    auto* buttons = new QDialogButtonBox(&dialog);
    auto* smart = buttons->addButton(QStringLiteral("Smart Checkout"),
                                     QDialogButtonBox::AcceptRole);
    smart->setProperty("primaryAction", true);
    smart->setDefault(true);
    auto* force = buttons->addButton(QStringLiteral("Force Checkout"),
                                     QDialogButtonBox::DestructiveRole);
    force->setProperty("destructiveAction", true);
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
    applyDialogChrome(&dialog);
    auto* layout = new QVBoxLayout(&dialog);
    layout->setContentsMargins(18, 16, 18, 16);
    layout->setSpacing(12);
    const auto summaryText = request.blocksEntirely
        ? QStringLiteral("%1 onto %2 requires a clean working tree.")
              .arg(QString::fromUtf8(app::integrationOperationTitle(request.operation)))
              .arg(QString::fromStdString(request.displayName))
        : QStringLiteral("%1 of %2 overlaps local changes.")
              .arg(QString::fromUtf8(app::integrationOperationTitle(request.operation)))
              .arg(QString::fromStdString(request.displayName));
    layout->addWidget(makeTitle(&dialog, summaryText));

    auto* list = makePathList(&dialog, toQtPaths(request.blockingPaths));
    layout->addWidget(list, 1);

    auto* buttons = new QDialogButtonBox(&dialog);
    auto* save = buttons->addButton(QStringLiteral("Save Changes and Continue"),
                                    QDialogButtonBox::AcceptRole);
    save->setProperty("primaryAction", true);
    save->setDefault(true);
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
    applyDialogChrome(&dialog);
    auto* layout = new QVBoxLayout(&dialog);
    layout->setContentsMargins(18, 16, 18, 16);
    layout->setSpacing(12);
    layout->addWidget(makeTitle(
        &dialog,
        QStringLiteral("Branch and %1 have diverged.")
            .arg(QString::fromStdString(request.upstream))));
    layout->addWidget(makeMeta(
        &dialog,
        QStringLiteral("Ahead %1 · Behind %2. Choose how to integrate.")
            .arg(static_cast<qulonglong>(request.ahead))
            .arg(static_cast<qulonglong>(request.behind))));

    auto* buttons = new QDialogButtonBox(&dialog);
    auto* ffOnly = buttons->addButton(QStringLiteral("Fast-forward only"),
                                      QDialogButtonBox::ActionRole);
    auto* merge = buttons->addButton(QStringLiteral("Merge"),
                                     QDialogButtonBox::AcceptRole);
    merge->setProperty("primaryAction", true);
    merge->setDefault(true);
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

std::optional<int> showGitReferencePickerDialog(
    QWidget* parent,
    const QString& title,
    const QString& prompt,
    const QStringList& choices,
    int currentIndex) {
    if (choices.isEmpty()) return std::nullopt;

    QDialog dialog(parent);
    dialog.setWindowTitle(title);
    applyDialogChrome(&dialog);
    dialog.setMinimumSize(460, 420);

    auto* layout = new QVBoxLayout(&dialog);
    layout->setContentsMargins(18, 16, 18, 16);
    layout->setSpacing(10);
    layout->addWidget(makeTitle(&dialog, title));
    if (!prompt.isEmpty()) {
        layout->addWidget(makeMeta(&dialog, prompt));
    }

    auto* filter = new QLineEdit(&dialog);
    filter->setPlaceholderText(QStringLiteral("Filter branches, tags, remotes…"));
    filter->setClearButtonEnabled(true);
    layout->addWidget(filter);

    auto* list = new QListWidget(&dialog);
    list->setUniformItemSizes(true);
    for (const auto& choice : choices) {
        list->addItem(choice);
    }
    if (currentIndex >= 0 && currentIndex < list->count()) {
        list->setCurrentRow(currentIndex);
    } else if (list->count() > 0) {
        list->setCurrentRow(0);
    }
    layout->addWidget(list, 1);

    auto* buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel,
                                         &dialog);
    if (auto* ok = buttons->button(QDialogButtonBox::Ok)) {
        ok->setText(QStringLiteral("Continue"));
        ok->setProperty("primaryAction", true);
        ok->setDefault(true);
    }
    layout->addWidget(buttons);

    QObject::connect(filter, &QLineEdit::textChanged, &dialog, [list](const QString& query) {
        for (int i = 0; i < list->count(); ++i) {
            auto* item = list->item(i);
            item->setHidden(!query.isEmpty() &&
                            !item->text().contains(query, Qt::CaseInsensitive));
        }
    });
    QObject::connect(list, &QListWidget::itemDoubleClicked, &dialog, [&](QListWidgetItem*) {
        if (list->currentItem() != nullptr) dialog.accept();
    });
    QObject::connect(buttons, &QDialogButtonBox::accepted, &dialog, &QDialog::accept);
    QObject::connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);

    if (dialog.exec() != QDialog::Accepted) return std::nullopt;
    const auto* item = list->currentItem();
    if (item == nullptr || item->isHidden()) return std::nullopt;
    const int index = choices.indexOf(item->text());
    if (index < 0) return std::nullopt;
    return index;
}

std::optional<QString> showGitTextInputDialog(
    QWidget* parent,
    const QString& title,
    const QString& prompt,
    const QString& initialValue) {
    QDialog dialog(parent);
    dialog.setWindowTitle(title);
    applyDialogChrome(&dialog);
    auto* layout = new QVBoxLayout(&dialog);
    layout->setContentsMargins(18, 16, 18, 16);
    layout->setSpacing(12);
    layout->addWidget(makeTitle(&dialog, title));
    if (!prompt.isEmpty()) {
        layout->addWidget(makeMeta(&dialog, prompt));
    }
    auto* field = new QLineEdit(initialValue, &dialog);
    field->selectAll();
    layout->addWidget(field);
    auto* buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel,
                                         &dialog);
    if (auto* ok = buttons->button(QDialogButtonBox::Ok)) {
        ok->setProperty("primaryAction", true);
        ok->setDefault(true);
    }
    layout->addWidget(buttons);
    QObject::connect(buttons, &QDialogButtonBox::accepted, &dialog, &QDialog::accept);
    QObject::connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
    QObject::connect(field, &QLineEdit::returnPressed, &dialog, &QDialog::accept);
    if (dialog.exec() != QDialog::Accepted) return std::nullopt;
    const auto value = field->text().trimmed();
    if (value.isEmpty()) return std::nullopt;
    return value;
}

bool confirmDestructiveGitAction(QWidget* parent,
                                 const QString& title,
                                 const QString& message) {
    QMessageBox box(parent);
    box.setIcon(QMessageBox::Warning);
    box.setWindowTitle(title);
    box.setText(message);
    box.setStandardButtons(QMessageBox::Ok | QMessageBox::Cancel);
    box.setDefaultButton(QMessageBox::Cancel);
    box.setStyleSheet(ui::litheDialogStyleSheet());
    if (auto* ok = box.button(QMessageBox::Ok)) {
        ok->setText(title);
        ok->setProperty("destructiveAction", true);
    }
    return box.exec() == QMessageBox::Ok;
}

} // namespace lithe::windows
