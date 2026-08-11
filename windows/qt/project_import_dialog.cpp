#include "project_import_dialog.h"

#include "ui_translation.h"

#include <QFileDialog>
#include <QFileInfo>
#include <QDialogButtonBox>
#include <QDir>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QMetaObject>
#include <QPointer>
#include <QPushButton>
#include <QTreeWidget>
#include <QVBoxLayout>

#include <filesystem>
#include <atomic>
#include <thread>

namespace lithe::windows {
namespace {

QString fromUtf8(const std::string& value) {
    return QString::fromUtf8(value.data(), static_cast<qsizetype>(value.size()));
}

}

ProjectImportDialog::ProjectImportDialog(FileStorage& storage,
                                         app::ProjectRuntimeService& runtime,
                                         QWidget* parent)
    : QDialog(parent),
      storage_(storage),
      runtimeService_(runtime),
      detection_(storage),
      alive_(std::make_shared<std::atomic_bool>(true)) {
    setWindowTitle(uiText(QStringLiteral("Open Project")));
    resize(760, 560);

    auto* outer = new QVBoxLayout(this);
    auto* rootRow = new QHBoxLayout();
    rootField_ = new QLineEdit(this);
    rootField_->setPlaceholderText(uiText(QStringLiteral("Workspace Root")));
    auto* browseButton = new QPushButton(uiText(QStringLiteral("Browse...")), this);
    rootRow->addWidget(rootField_, 1);
    rootRow->addWidget(browseButton);
    outer->addLayout(rootRow);

    status_ = new QLabel(uiText(QStringLiteral("Choose a folder to scan.")), this);
    status_->setWordWrap(true);
    outer->addWidget(status_);

    auto* form = new QFormLayout();
    kind_ = new QLabel(uiText(QStringLiteral("Not scanned")), this);
    runtime_ = new QLabel(uiText(QStringLiteral("Runtime readiness is checked after detection.")), this);
    runtime_->setWordWrap(true);
    form->addRow(uiText(QStringLiteral("Project kind")), kind_);
    form->addRow(uiText(QStringLiteral("Runtime")), runtime_);
    outer->addLayout(form);

    details_ = new QTreeWidget(this);
    details_->setHeaderLabels({uiText(QStringLiteral("Evidence and modules"))});
    details_->setRootIsDecorated(true);
    outer->addWidget(details_, 1);

    auto* buttons = new QDialogButtonBox(QDialogButtonBox::Cancel, this);
    open_ = new QPushButton(uiText(QStringLiteral("Open Project")), this);
    open_->setEnabled(false);
    buttons->addButton(open_, QDialogButtonBox::AcceptRole);
    outer->addWidget(buttons);

    connect(browseButton, &QPushButton::clicked, this, &ProjectImportDialog::browse);
    connect(rootField_, &QLineEdit::returnPressed, this, [this] { scanRoot(rootField_->text()); });
    connect(open_, &QPushButton::clicked, this, [this] {
        if (!candidate_) return;
        selection_ = ProjectImportSelection{rootField_->text().trimmed().toUtf8().toStdString(), *candidate_};
        accept();
    });
    connect(buttons, &QDialogButtonBox::rejected, this, &QDialog::reject);
}

ProjectImportDialog::~ProjectImportDialog() {
    alive_->store(false);
    ++generation_;
}

std::optional<ProjectImportSelection> ProjectImportDialog::run(const QString& initialRoot) {
    selection_.reset();
    candidate_.reset();
    rootField_->setText(initialRoot);
    if (!initialRoot.trimmed().isEmpty()) scanRoot(initialRoot);
    exec();
    return selection_;
}

void ProjectImportDialog::browse() {
    const auto selected = QFileDialog::getExistingDirectory(
        this, uiText(QStringLiteral("Choose Workspace Root")), rootField_->text());
    if (!selected.isEmpty()) {
        rootField_->setText(selected);
        scanRoot(selected);
    }
}

void ProjectImportDialog::scanRoot(const QString& root) {
    const auto normalized = QFileInfo(QDir::fromNativeSeparators(root.trimmed())).absoluteFilePath();
    if (normalized.isEmpty() || !QFileInfo(normalized).isDir()) {
        candidate_.reset();
        open_->setEnabled(false);
        status_->setText(uiText(QStringLiteral("Choose an existing folder.")));
        return;
    }
    rootField_->setText(normalized);
    candidate_.reset();
    open_->setEnabled(false);
    details_->clear();
    kind_->setText(uiText(QStringLiteral("Scanning...")));
    runtime_->setText(uiText(QStringLiteral("Scanning project markers and Java sources...")));
    status_->setText(uiText(QStringLiteral("Detecting project candidates...")));
    const auto generation = ++generation_;
    const auto rootPath = std::filesystem::path(normalized.toStdWString());
    const auto alive = alive_;
    const QPointer<ProjectImportDialog> dialog(this);
    auto* storage = &storage_;
    auto* runtime = &runtimeService_;
    std::thread([alive, dialog, storage, runtime, generation, rootPath] {
        app::ProjectDetectionService detection(*storage);
        auto result = detection.detect(rootPath);
        RuntimeReadiness readiness;
        const auto discovered = runtime->discover();
        readiness.jdk = !discovered.javaRuntimes.empty();
        readiness.wrapper = !result.candidates.empty() &&
            (result.candidates.front().hasMavenWrapper || result.candidates.front().hasGradleWrapper);
        if (!result.candidates.empty()) {
            app::ProjectRuntimeSettings settings;
            const auto& candidate = result.candidates.front();
            readiness.maven = runtime->mavenExecutable(rootPath, settings).has_value();
        } else {
            readiness.maven = !discovered.mavenRuntimes.empty() ||
                runtime->mavenExecutable(rootPath, {}).has_value();
        }
        if (!alive->load() || dialog.isNull()) return;
        QMetaObject::invokeMethod(dialog, [dialog, generation,
                                           result = std::move(result), readiness]() mutable {
            if (dialog.isNull()) return;
            dialog->applyResult(generation, std::move(result), readiness);
        }, Qt::QueuedConnection);
    }).detach();
}

void ProjectImportDialog::applyResult(std::uint64_t generation,
                                      app::ProjectDetectionResult result,
                                      RuntimeReadiness readiness) {
    if (generation != generation_) return;
    if (result.candidates.empty()) {
        candidate_ = app::ProjectCandidate{};
        candidate_->root = result.workspaceRoot;
        kind_->setText(uiText(QStringLiteral("Unknown")));
        runtime_->setText(uiText(QStringLiteral("JDK: %1 | Maven: %2")
            .arg(readiness.jdk ? uiText(QStringLiteral("Ready")) : uiText(QStringLiteral("Missing")))
            .arg(readiness.maven ? uiText(QStringLiteral("Ready")) : uiText(QStringLiteral("Missing")))));
        status_->setText(uiText(QStringLiteral("No project markers found. You can still open this folder.")));
        details_->clear();
        open_->setEnabled(true);
        return;
    }
    candidate_ = std::move(result.candidates.front());
    showCandidate(*candidate_, readiness);
    open_->setEnabled(true);
    status_->setText(uiText(QStringLiteral("Project candidate ready. Confirm to open the workspace.")));
}

void ProjectImportDialog::showCandidate(const app::ProjectCandidate& candidate,
                                        RuntimeReadiness readiness) {
    kind_->setText(projectKindText(candidate.kind));
    runtime_->setText(uiText(QStringLiteral("JDK: %1 | Maven: %2 | Wrapper: %3"))
        .arg(readiness.jdk ? uiText(QStringLiteral("Ready")) : uiText(QStringLiteral("Missing")))
        .arg(readiness.maven ? uiText(QStringLiteral("Ready")) : uiText(QStringLiteral("Missing")))
        .arg(readiness.wrapper ? uiText(QStringLiteral("Ready")) : uiText(QStringLiteral("Missing"))));
    details_->clear();
    auto* evidence = new QTreeWidgetItem(details_, {uiText(QStringLiteral("Evidence"))});
    for (const auto& item : candidate.evidence) {
        new QTreeWidgetItem(evidence, {fromUtf8(item.relativePath) + QStringLiteral("  ") + fromUtf8(item.detail)});
    }
    auto* modules = new QTreeWidgetItem(details_, {uiText(QStringLiteral("Modules"))});
    for (const auto& module : candidate.modules) {
        auto* item = new QTreeWidgetItem(modules, {fromUtf8(module.relativePath) + QStringLiteral("  ") + projectKindText(module.kind)});
        for (const auto& itemEvidence : module.evidence) {
            new QTreeWidgetItem(item, {fromUtf8(itemEvidence.relativePath) + QStringLiteral("  ") + fromUtf8(itemEvidence.detail)});
        }
    }
    details_->expandAll();
}

QString ProjectImportDialog::projectKindText(app::ProjectKind kind) {
    switch (kind) {
    case app::ProjectKind::Maven: return uiText(QStringLiteral("Maven"));
    case app::ProjectKind::Gradle: return uiText(QStringLiteral("Gradle"));
    case app::ProjectKind::Eclipse: return uiText(QStringLiteral("Eclipse"));
    case app::ProjectKind::IntelliJ: return uiText(QStringLiteral("IntelliJ"));
    case app::ProjectKind::PlainJava: return uiText(QStringLiteral("Plain Java"));
    case app::ProjectKind::Mixed: return uiText(QStringLiteral("Mixed project"));
    case app::ProjectKind::Unknown: return uiText(QStringLiteral("Unknown"));
    }
    return uiText(QStringLiteral("Unknown"));
}

}
