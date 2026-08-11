#include "workbench_code_editor.h"

#include "syntax_highlighter.h"

#include <QColor>
#include <QAbstractSlider>
#include <QFont>
#include <QFontDatabase>
#include <QPalette>
#include <QPainter>
#include <QPaintEvent>
#include <QResizeEvent>
#include <QScrollBar>
#include <QSyntaxHighlighter>
#include <QTextBlock>
#include <QTextBlockFormat>
#include <QTextCharFormat>
#include <QTextCursor>
#include <QTextDocument>
#include <QTextLayout>
#include <QStringList>

#include <algorithm>
#include <cstddef>
#include <string_view>
#include <utility>

namespace lithe::windows {
namespace {

QColor colorForToken(algorithms::SyntaxHighlightKind kind) {
    switch (kind) {
    case algorithms::SyntaxHighlightKind::Keyword:
        return QColor(42, 91, 170);
    case algorithms::SyntaxHighlightKind::Annotation:
        return QColor(143, 74, 145);
    case algorithms::SyntaxHighlightKind::Type:
        return QColor(20, 118, 111);
    case algorithms::SyntaxHighlightKind::Number:
        return QColor(156, 93, 20);
    case algorithms::SyntaxHighlightKind::String:
        return QColor(126, 91, 24);
    case algorithms::SyntaxHighlightKind::Comment:
        return QColor(105, 112, 122);
    }
    return QColor(30, 33, 38);
}

int utf16OffsetForUtf8Byte(const QByteArray& utf8, std::size_t byteOffset) {
    const auto bounded = std::min(byteOffset, static_cast<std::size_t>(utf8.size()));
    return QString::fromUtf8(utf8.constData(), static_cast<qsizetype>(bounded)).size();
}

class WorkbenchSyntaxHighlighter final : public QSyntaxHighlighter {
public:
    explicit WorkbenchSyntaxHighlighter(QTextDocument* document)
        : QSyntaxHighlighter(document) {}

protected:
    void highlightBlock(const QString& text) override {
        const auto utf8 = text.toUtf8();
        const auto spans = algorithms::highlightSyntax(
            std::string_view(utf8.constData(), static_cast<std::size_t>(utf8.size())));
        for (const auto& span : spans) {
            const auto start = utf16OffsetForUtf8Byte(utf8, span.start);
            const auto end = utf16OffsetForUtf8Byte(utf8, span.end);
            if (end <= start) continue;
            QTextCharFormat format;
            format.setForeground(colorForToken(span.kind));
            if (span.kind == algorithms::SyntaxHighlightKind::Comment) {
                format.setFontItalic(true);
            }
            setFormat(start, end - start, format);
        }
    }
};

} // namespace

class WorkbenchEditorGutter final : public QWidget {
public:
    explicit WorkbenchEditorGutter(WorkbenchCodeEditor* editor)
        : QWidget(editor), editor_(editor) {
        setAutoFillBackground(true);
    }

protected:
    void paintEvent(QPaintEvent* event) override {
        editor_->paintGutter(event);
    }

private:
    WorkbenchCodeEditor* editor_ = nullptr;
};

WorkbenchCodeEditor::WorkbenchCodeEditor(QWidget* parent)
    : QPlainTextEdit(parent) {
    setFont(QFontDatabase::systemFont(QFontDatabase::FixedFont));
    setLineWrapMode(QPlainTextEdit::NoWrap);
    new WorkbenchSyntaxHighlighter(document());

    gutter_ = new WorkbenchEditorGutter(this);
    connect(this, &QPlainTextEdit::blockCountChanged, this,
            [this] { updateGutterWidth(); });
    connect(this, &QPlainTextEdit::updateRequest, this,
            [this](const QRect& rect, int dy) {
                if (dy != 0) gutter_->scroll(0, dy);
                else gutter_->update(0, rect.y(), gutter_->width(), rect.height());
                if (rect.contains(viewport()->rect())) gutter_->update();
            });
    connect(verticalScrollBar(), &QAbstractSlider::valueChanged, this,
            [this] { gutter_->update(); });
    updateGutterWidth();
}

void WorkbenchCodeEditor::setCodeVision(
    std::vector<EditorCodeVisionAnnotation> codeVision) {
    codeVision_ = std::move(codeVision);
    std::sort(codeVision_.begin(), codeVision_.end(), [](const auto& left, const auto& right) {
        return left.line < right.line;
    });
    updateCodeVisionMargins();
    viewport()->update();
}

void WorkbenchCodeEditor::setImplementationMarkers(
    std::vector<EditorCodeVisionAnnotation> markers) {
    implementationMarkers_ = std::move(markers);
    std::sort(implementationMarkers_.begin(), implementationMarkers_.end(),
              [](const auto& left, const auto& right) { return left.line < right.line; });
    updateCodeVisionMargins();
    viewport()->update();
}

void WorkbenchCodeEditor::setInlayHints(std::vector<EditorInlayAnnotation> inlays) {
    inlays_ = std::move(inlays);
    viewport()->update();
}

void WorkbenchCodeEditor::setBlameAnnotations(
    std::vector<EditorBlameAnnotation> blame) {
    blame_ = std::move(blame);
    std::sort(blame_.begin(), blame_.end(), [](const auto& left, const auto& right) {
        return left.line < right.line;
    });
    if (gutter_ != nullptr) gutter_->update();
}

void WorkbenchCodeEditor::setBreakpoints(std::vector<int> lines) {
    lines.erase(std::remove_if(lines.begin(), lines.end(), [](int line) { return line < 0; }),
                lines.end());
    std::sort(lines.begin(), lines.end());
    lines.erase(std::unique(lines.begin(), lines.end()), lines.end());
    breakpoints_ = std::move(lines);
    if (gutter_ != nullptr) gutter_->update();
}

void WorkbenchCodeEditor::setBlameVisible(bool visible) {
    if (blameVisible_ == visible) return;
    blameVisible_ = visible;
    updateGutterWidth();
    if (gutter_ != nullptr) gutter_->update();
}

void WorkbenchCodeEditor::clearAnnotations() {
    codeVision_.clear();
    implementationMarkers_.clear();
    inlays_.clear();
    blame_.clear();
    breakpoints_.clear();
    updateCodeVisionMargins();
    viewport()->update();
    if (gutter_ != nullptr) gutter_->update();
}

void WorkbenchCodeEditor::updateCodeVisionMargins() {
    auto* document = this->document();
    const auto wasBlocked = document->blockSignals(true);
    for (auto block = document->begin(); block.isValid(); block = block.next()) {
        auto format = block.blockFormat();
        if (format.topMargin() == 0.0) continue;
        format.setTopMargin(0.0);
        QTextCursor cursor(block);
        cursor.setBlockFormat(format);
    }
    document->blockSignals(wasBlocked);
    updateGutterWidth();
    document->documentLayout()->update();
}

void WorkbenchCodeEditor::updateGutterWidth() {
    if (gutter_ == nullptr) return;
    const auto hasCodeVision = !codeVision_.empty() || !implementationMarkers_.empty();
    const auto width = blameVisible_ ? 232 : (hasCodeVision ? 240 : 52);
    setViewportMargins(width, 0, 0, 0);
    gutter_->setGeometry(0, 0, width, height());
}

void WorkbenchCodeEditor::resizeEvent(QResizeEvent* event) {
    QPlainTextEdit::resizeEvent(event);
    updateGutterWidth();
}

void WorkbenchCodeEditor::paintGutter(QPaintEvent* event) {
    if (gutter_ == nullptr) return;
    QPainter painter(gutter_);
    painter.fillRect(event->rect(), palette().alternateBase());
    painter.setRenderHint(QPainter::TextAntialiasing);

    const auto contentOffset = QPlainTextEdit::contentOffset();
    auto block = firstVisibleBlock();
    const auto blameForLine = [this](int line) -> const EditorBlameAnnotation* {
        const auto found = std::lower_bound(
            blame_.begin(), blame_.end(), line,
            [](const EditorBlameAnnotation& value, int requested) {
                return value.line < requested;
            });
        return found != blame_.end() && found->line == line ? &*found : nullptr;
    };
    const auto codeVisionForLine = [this](int line) {
        QStringList annotations;
        for (const auto& annotation : codeVision_) {
            if (annotation.line == line) annotations.push_back(annotation.text);
        }
        for (const auto& annotation : implementationMarkers_) {
            if (annotation.line == line) annotations.push_back(annotation.text);
        }
        return annotations.join(QStringLiteral("  |  "));
    };

    while (block.isValid()) {
        const auto blockRect = blockBoundingGeometry(block).translated(contentOffset);
        if (blockRect.top() > event->rect().bottom()) break;
        if (block.isVisible() && blockRect.bottom() >= event->rect().top()) {
            const auto line = block.blockNumber();
            const auto textTop = blockRect.top();
            const auto baseline = qRound(textTop) + fontMetrics().ascent();
            const auto lineNumber = QString::number(line + 1);
            painter.setPen(palette().color(QPalette::Mid));
            if (blameVisible_) {
                if (const auto* blame = blameForLine(line)) {
                    painter.setPen(palette().color(QPalette::PlaceholderText));
                    painter.drawText(6, baseline, blame->date);
                    const auto author = fontMetrics().elidedText(
                        blame->author, Qt::ElideRight, 116);
                    painter.drawText(74, baseline, author);
                }
            } else if (std::binary_search(breakpoints_.begin(), breakpoints_.end(), line)) {
                painter.setPen(Qt::NoPen);
                painter.setBrush(QColor(214, 67, 73));
                painter.drawEllipse(QPointF(14, textTop + fontMetrics().height() / 2.0),
                                    5.0, 5.0);
                painter.setBrush(Qt::NoBrush);
                painter.setPen(palette().color(QPalette::Mid));
            }
            const auto lineNumberWidth = blameVisible_ ? gutter_->width() - 8 : 44;
            painter.setFont(font());
            painter.drawText(0, baseline, lineNumberWidth,
                             fontMetrics().height(), Qt::AlignRight, lineNumber);
            if (!blameVisible_) {
                const auto annotation = codeVisionForLine(line);
                const auto annotationWidth = gutter_->width() - 58;
                if (!annotation.isEmpty() && annotationWidth > 0) {
                    auto annotationFont = font();
                    annotationFont.setPointSize(qMax(8, font().pointSize() - 2));
                    annotationFont.setItalic(true);
                    painter.setFont(annotationFont);
                    painter.setPen(palette().color(QPalette::PlaceholderText));
                    painter.drawText(52, baseline, annotationWidth,
                                     painter.fontMetrics().height(), Qt::AlignLeft,
                                     painter.fontMetrics().elidedText(
                                         annotation, Qt::ElideRight, annotationWidth));
                }
            }
        }
        block = block.next();
    }
}

void WorkbenchCodeEditor::paintEvent(QPaintEvent* event) {
    QPlainTextEdit::paintEvent(event);

    QPainter painter(viewport());
    painter.setRenderHint(QPainter::TextAntialiasing);
    const auto contentOffset = QPlainTextEdit::contentOffset();
    const auto visibleRect = event->rect();
    const auto textColor = palette().color(QPalette::Text);
    const auto inlayColor = QColor(textColor.red(), textColor.green(), textColor.blue(), 125);

    painter.setFont(font());
    for (const auto& annotation : inlays_) {
        const auto block = document()->findBlockByNumber(annotation.line);
        if (!block.isValid() || !block.isVisible()) continue;
        const auto rect = blockBoundingGeometry(block).translated(contentOffset);
        if (!rect.intersects(visibleRect)) continue;
        const auto* layout = block.layout();
        if (layout == nullptr || layout->lineCount() == 0) continue;
        const auto line = layout->lineAt(0);
        const auto column = std::clamp(annotation.utf16Column, 0,
                                      static_cast<int>(block.text().size()));
        const auto x = line.cursorToX(column);
        const auto y = rect.top() + line.ascent();
        const auto textWidth = painter.fontMetrics().horizontalAdvance(annotation.text);
        painter.setPen(inlayColor);
        painter.drawText(QPointF(rect.left() + x + 4.0, y), annotation.text);
        painter.setPen(QColor(inlayColor.red(), inlayColor.green(), inlayColor.blue(), 65));
        painter.drawLine(QPointF(rect.left() + x + 2.0, y + 2.0),
                         QPointF(rect.left() + x + textWidth + 6.0, y + 2.0));
    }
}

} // namespace lithe::windows
