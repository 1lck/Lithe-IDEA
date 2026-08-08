#pragma once

#include "project_detection_service.h"
#include "project_runtime_service.h"

#include <QDialog>

#include <atomic>
#include <cstdint>
#include <optional>
#include <string>
#include <memory>

class QLabel;
class QLineEdit;
class QPushButton;
class QTreeWidget;

namespace lithe::windows {

struct ProjectImportSelection {
    std::string workspaceRoot;
    app::ProjectCandidate candidate;
};

class ProjectImportDialog final : public QDialog {
    Q_OBJECT

public:
    explicit ProjectImportDialog(FileStorage& storage,
                                 app::ProjectRuntimeService& runtime,
                                 QWidget* parent = nullptr);
    ~ProjectImportDialog() override;

    std::optional<ProjectImportSelection> run(const QString& initialRoot = {});

private:
    void browse();
    void scanRoot(const QString& root);
    struct RuntimeReadiness {
        bool jdk = false;
        bool maven = false;
        bool wrapper = false;
    };

    void applyResult(std::uint64_t generation,
                     app::ProjectDetectionResult result,
                     RuntimeReadiness readiness);
    void showCandidate(const app::ProjectCandidate& candidate, RuntimeReadiness readiness);
    static QString projectKindText(app::ProjectKind kind);

    FileStorage& storage_;
    app::ProjectRuntimeService& runtimeService_;
    app::ProjectDetectionService detection_;
    std::shared_ptr<std::atomic_bool> alive_;
    std::uint64_t generation_ = 0;
    std::optional<app::ProjectCandidate> candidate_;
    std::optional<ProjectImportSelection> selection_;
    QLineEdit* rootField_ = nullptr;
    QLabel* status_ = nullptr;
    QLabel* kind_ = nullptr;
    QLabel* runtime_ = nullptr;
    QTreeWidget* details_ = nullptr;
    QPushButton* open_ = nullptr;
};

}
