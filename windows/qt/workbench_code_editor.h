#pragma once

#include <QPlainTextEdit>
#include <QString>

#include <vector>

class QPaintEvent;
class QResizeEvent;

namespace lithe::windows {

struct EditorCodeVisionAnnotation {
    int line = 0;
    QString text;
};

struct EditorInlayAnnotation {
    int line = 0;
    int utf16Column = 0;
    QString text;
};

struct EditorBlameAnnotation {
    int line = 0;
    QString author;
    QString date;
};

class WorkbenchEditorGutter;

class WorkbenchCodeEditor final : public QPlainTextEdit {
public:
    explicit WorkbenchCodeEditor(QWidget* parent = nullptr);

    void setCodeVision(std::vector<EditorCodeVisionAnnotation> codeVision);
    void setImplementationMarkers(std::vector<EditorCodeVisionAnnotation> markers);
    void setInlayHints(std::vector<EditorInlayAnnotation> inlays);
    void setBlameAnnotations(std::vector<EditorBlameAnnotation> blame);
    void setBreakpoints(std::vector<int> lines);
    void setBlameVisible(bool visible);
    bool blameVisible() const { return blameVisible_; }
    void clearAnnotations();

protected:
    void paintEvent(QPaintEvent* event) override;
    void resizeEvent(QResizeEvent* event) override;

private:
    friend class WorkbenchEditorGutter;

    void updateCodeVisionMargins();
    void updateGutterWidth();
    void paintGutter(QPaintEvent* event);

    std::vector<EditorCodeVisionAnnotation> codeVision_;
    std::vector<EditorCodeVisionAnnotation> implementationMarkers_;
    std::vector<EditorInlayAnnotation> inlays_;
    std::vector<EditorBlameAnnotation> blame_;
    std::vector<int> breakpoints_;
    QWidget* gutter_ = nullptr;
    bool blameVisible_ = false;
};

} // namespace lithe::windows
