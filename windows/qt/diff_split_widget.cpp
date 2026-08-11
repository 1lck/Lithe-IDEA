#include "diff_split_widget.h"

#include "diff_tokenizer.h"
#include "inline_diff.h"
#include "workbench_icons.h"
#include "workbench_ui_theme.h"

#include <QFont>
#include <QFontMetrics>
#include <QFrame>
#include <QHBoxLayout>
#include <QLabel>
#include <QMouseEvent>
#include <QPainter>
#include <QPainterPath>
#include <QPushButton>
#include <QResizeEvent>
#include <QScrollArea>
#include <QScrollBar>
#include <QSet>
#include <QToolButton>
#include <QVBoxLayout>

#include <algorithm>
#include <cmath>
#include <string_view>

namespace lithe::windows {
namespace {

constexpr int kRowHeight = 22;
constexpr int kInfoRowHeight = 26;
constexpr int kLineNumberWidth = 52;
constexpr int kMarkerWidth = 3;
constexpr int kGutterWidth = 36;
constexpr int kTextPad = 8;

// Soft platform-aligned diff tints (LitheTheme success/error at low alpha).
QColor rowBackground(algorithms::DiffRowKind kind, bool leftSide) {
    using K = algorithms::DiffRowKind;
    switch (kind) {
    case K::Changed:
        return leftSide ? QColor(235, 84, 84, 38) : QColor(71, 184, 99, 42);
    case K::Removal:
        return leftSide ? QColor(235, 84, 84, 48) : QColor(0, 0, 0, 0);
    case K::Addition:
        return leftSide ? QColor(0, 0, 0, 0) : QColor(71, 184, 99, 48);
    case K::Information:
        return QColor(36, 48, 64, 180);
    case K::Context:
        return QColor(0, 0, 0, 0);
    }
    return QColor(0, 0, 0, 0);
}

QColor markerColor(algorithms::DiffRowKind kind, bool leftSide) {
    using K = algorithms::DiffRowKind;
    switch (kind) {
    case K::Changed:
        return leftSide ? QColor(235, 84, 84, 160) : QColor(71, 184, 99, 160);
    case K::Removal:
        return leftSide ? QColor(235, 84, 84, 190) : QColor(0, 0, 0, 0);
    case K::Addition:
        return leftSide ? QColor(0, 0, 0, 0) : QColor(71, 184, 99, 190);
    default:
        return QColor(0, 0, 0, 0);
    }
}

QColor ribbonFill(const algorithms::DiffTransition& transition) {
    if (transition.isRemoval()) return QColor(235, 84, 84, 46);
    return QColor(71, 184, 99, 46);
}

QColor ribbonStroke(const algorithms::DiffTransition& transition) {
    if (transition.isRemoval()) return QColor(235, 84, 84, 128);
    return QColor(71, 184, 99, 128);
}

QString fromUtf8(std::string_view value) {
    return QString::fromUtf8(value.data(), static_cast<qsizetype>(value.size()));
}

// Matches DiffSyntaxHighlighter token colors from the reference diff renderer.
QColor tokenForeground(algorithms::DiffTokenKind kind) {
    using K = algorithms::DiffTokenKind;
    switch (kind) {
    case K::Keyword:
        return QColor::fromRgbF(0.82, 0.52, 0.78);
    case K::Type:
        return QColor::fromRgbF(0.43, 0.72, 0.92);
    case K::String:
        return QColor::fromRgbF(0.58, 0.76, 0.49);
    case K::Number:
        return QColor::fromRgbF(0.70, 0.76, 0.48);
    case K::Comment:
        return QColor::fromRgbF(0.39, 0.57, 0.43);
    case K::Tag:
        return QColor::fromRgbF(0.82, 0.66, 0.37);
    case K::Base:
        return ui::Theme::primaryText();
    }
    return ui::Theme::primaryText();
}

std::size_t utf8ScalarLength(std::string_view bytes, std::size_t index) {
    if (index >= bytes.size()) return 0;
    const auto first = static_cast<unsigned char>(bytes[index]);
    if (first < 0x80) return 1;
    if (first >= 0xc2 && first <= 0xdf) return 2;
    if (first >= 0xe0 && first <= 0xef) return 3;
    if (first >= 0xf0 && first <= 0xf4) return 4;
    return 1;
}

/// Paint reference-diff syntax and word highlights (DiffSyntaxHighlighter.styled).
void paintStyledDiffText(QPainter& painter,
                         const QFontMetrics& metrics,
                         const QRect& textRect,
                         std::string_view text,
                         std::string_view fileExtension,
                         bool leftSide,
                         bool highlightWords,
                         std::optional<std::string_view> otherText) {
    if (text.empty() || textRect.width() <= 0) return;

    painter.save();
    painter.setClipRect(textRect);

    const auto tokens = algorithms::tokenizeDiffText(text, fileExtension);
    std::optional<algorithms::InlineChangedRange> changed;
    if (highlightWords) changed = algorithms::changedRange(text, otherText);
    const QColor highlightBg =
        leftSide ? QColor(255, 59, 48, 97) : QColor(52, 199, 89, 87);

    int cursorX = textRect.left();
    const int baseline =
        textRect.top() + (textRect.height() + metrics.ascent() - metrics.descent()) / 2;
    std::size_t scalarPos = 0;

    for (const auto& token : tokens) {
        const auto& bytes = token.text;
        const QColor fg = tokenForeground(token.kind);
        std::size_t index = 0;
        while (index < bytes.size()) {
            const auto len = utf8ScalarLength(bytes, index);
            if (len == 0 || index + len > bytes.size()) break;
            const QString ch =
                QString::fromUtf8(bytes.data() + static_cast<std::ptrdiff_t>(index),
                                  static_cast<qsizetype>(len));
            const int advance = metrics.horizontalAdvance(ch);
            if (cursorX > textRect.right()) break;

            const bool inHighlight = changed &&
                scalarPos >= changed->start && scalarPos < changed->end;
            if (inHighlight) {
                painter.fillRect(QRect(cursorX, textRect.top() + 2, advance,
                                       textRect.height() - 4),
                                 highlightBg);
            }
            painter.setPen(fg);
            painter.drawText(cursorX, baseline, ch);
            cursorX += advance;
            ++scalarPos;
            index += len;
        }
    }

    painter.restore();
}

QLabel* makeBadge(QWidget* parent, const QColor& color) {
    auto* badge = new QLabel(parent);
    badge->setAlignment(Qt::AlignCenter);
    badge->setFixedHeight(18);
    badge->setStyleSheet(QStringLiteral(
        "QLabel {"
        "  color: %1;"
        "  background-color: %2;"
        "  border-radius: 4px;"
        "  padding: 0 7px;"
        "  font-size: 9px;"
        "  font-weight: 700;"
        "  letter-spacing: 0.04em;"
        "}")
                             .arg(ui::Theme::rgba(color),
                                  ui::Theme::rgba(QColor(color.red(), color.green(),
                                                         color.blue(), 28))));
    badge->setVisible(false);
    return badge;
}

QWidget* makeToolbarChip(QWidget* parent, const QString& text) {
    auto* chip = new QLabel(text, parent);
    chip->setAlignment(Qt::AlignCenter);
    chip->setFixedHeight(28);
    chip->setStyleSheet(QStringLiteral(
        "QLabel {"
        "  color: %1;"
        "  background-color: rgba(42, 45, 48, 148);"
        "  border-radius: 5px;"
        "  padding: 0 10px;"
        "  font-size: 11.5px;"
        "  font-weight: 500;"
        "}").arg(ui::Theme::rgba(ui::Theme::primaryText())));
    return chip;
}

} // namespace

class DiffSplitWidget::Canvas final : public QWidget {
public:
    explicit Canvas(DiffSplitWidget* owner) : QWidget(owner), owner_(owner) {
        setMouseTracking(true);
        QFont font(QStringLiteral("Cascadia Mono"));
        font.setStyleHint(QFont::Monospace);
        font.setFamilies({QStringLiteral("Cascadia Mono"), QStringLiteral("Consolas"),
                          QStringLiteral("Courier New")});
        font.setPointSize(10);
        setFont(font);
        setAutoFillBackground(true);
        QPalette pal = palette();
        pal.setColor(QPalette::Window, ui::Theme::editor());
        setPalette(pal);
    }

    void setLayoutData(algorithms::DiffSplitLayout layout,
                       std::vector<algorithms::DiffDisplayRow> displayRows,
                       const QString& selectedHunkId,
                       const QString& fileExtension) {
        layout_ = std::move(layout);
        displayRows_ = std::move(displayRows);
        selectedHunkId_ = selectedHunkId;
        fileExtension_ = fileExtension;
        const auto height = static_cast<int>(std::ceil(layout_.contentHeight()));
        setMinimumHeight(std::max(height, 120));
        updateGeometry();
        update();
    }

    double scrollYForHunk(const QString& hunkId) const {
        for (const auto& item : layout_.rightItems) {
            if (!item.displayRow.isCollapsed() &&
                fromUtf8(item.displayRow.row().hunkId) == hunkId) {
                return item.top;
            }
        }
        for (const auto& item : layout_.leftItems) {
            if (!item.displayRow.isCollapsed() &&
                fromUtf8(item.displayRow.row().hunkId) == hunkId) {
                return item.top;
            }
        }
        return 0;
    }

protected:
    void paintEvent(QPaintEvent*) override {
        QPainter painter(this);
        painter.fillRect(rect(), ui::Theme::editor());
        painter.setRenderHint(QPainter::Antialiasing, true);

        const auto width = this->width();
        const auto paneWidth = std::max(0, (width - kGutterWidth) / 2);
        const auto gutterStart = paneWidth;
        const auto gutterEnd = paneWidth + kGutterWidth;

        painter.fillRect(QRect(gutterStart, 0, kGutterWidth, height()),
                         QColor(23, 25, 27));
        painter.setPen(QPen(ui::Theme::divider(), 1));
        painter.drawLine(gutterStart, 0, gutterStart, height());
        painter.drawLine(gutterEnd - 1, 0, gutterEnd - 1, height());

        paintSide(painter, layout_.leftItems, 0, paneWidth, true);
        paintSide(painter, layout_.rightItems, gutterEnd, paneWidth, false);
        paintRibbons(painter, paneWidth, gutterEnd);
    }

    void mousePressEvent(QMouseEvent* event) override {
        if (event->button() != Qt::LeftButton) return;
        const auto width = this->width();
        const auto paneWidth = std::max(0, (width - kGutterWidth) / 2);
        const auto x = event->position().x();
        const auto y = event->position().y();
        const bool left = x < paneWidth;
        const auto& items = left ? layout_.leftItems : layout_.rightItems;
        for (const auto& item : items) {
            if (y < item.top || y >= item.top + item.height) continue;
            if (item.displayRow.isCollapsed()) {
                owner_->notifyExpandRegion(fromUtf8(item.displayRow.region().id));
                return;
            }
            const auto& row = item.displayRow.row();
            if (!row.hunkId.empty()) {
                selectedHunkId_ = fromUtf8(row.hunkId);
                owner_->notifyHunkSelected(selectedHunkId_);
                update();
            }
            return;
        }
    }

private:
    void paintSide(QPainter& painter,
                   const std::vector<algorithms::DiffLayoutItem>& items,
                   int x,
                   int paneWidth,
                   bool leftSide) {
        if (paneWidth <= 0) return;
        QFont mono = font();
        QFontMetrics metrics(mono);

        for (const auto& item : items) {
            const QRect rowRect(x, static_cast<int>(item.top), paneWidth,
                                static_cast<int>(item.height));
            if (item.displayRow.isCollapsed()) {
                painter.fillRect(rowRect, QColor(31, 40, 52));
                painter.setPen(QColor(128, 170, 220, 200));
                const auto& region = item.displayRow.region();
                const auto text = QStringLiteral("⋯  %1 unchanged lines — click to expand")
                                      .arg(static_cast<qulonglong>(region.hiddenRowCount()));
                painter.drawText(rowRect.adjusted(12, 0, -8, 0),
                                 Qt::AlignVCenter | Qt::AlignLeft, text);
                continue;
            }

            const auto& row = item.displayRow.row();
            const auto kind = item.kind;
            const auto bg = rowBackground(kind, leftSide);
            if (bg.alpha() > 0) painter.fillRect(rowRect, bg);

            painter.fillRect(QRect(x, rowRect.top(), kLineNumberWidth, rowRect.height()),
                             QColor(17, 18, 20, 200));
            const auto marker = markerColor(kind, leftSide);
            if (marker.alpha() > 0) {
                painter.fillRect(
                    QRect(x + kLineNumberWidth, rowRect.top(), kMarkerWidth, rowRect.height()),
                    marker);
            }

            const auto selected = !selectedHunkId_.isEmpty() &&
                fromUtf8(row.hunkId) == selectedHunkId_;
            if (selected) {
                painter.fillRect(QRect(x, rowRect.top(), 2, rowRect.height()),
                                 ui::Theme::accent());
                painter.fillRect(rowRect, QColor(79, 148, 250, 18));
            }

            painter.setFont(mono);
            const auto lineNo = leftSide ? row.oldLine : row.newLine;
            QString lineLabel;
            if (kind == algorithms::DiffRowKind::Addition && !leftSide) {
                lineLabel = QStringLiteral("+");
                painter.setPen(QColor(71, 184, 99, 230));
            } else if (kind == algorithms::DiffRowKind::Removal && leftSide) {
                lineLabel = QStringLiteral("−");
                painter.setPen(QColor(235, 84, 84, 230));
            } else {
                painter.setPen(ui::Theme::tertiaryText());
            }
            if (lineNo) {
                if (!lineLabel.isEmpty()) lineLabel += QLatin1Char(' ');
                lineLabel += QString::number(static_cast<qulonglong>(*lineNo));
            }
            if (!lineLabel.isEmpty()) {
                painter.drawText(
                    QRect(x + 2, rowRect.top(), kLineNumberWidth - 6, rowRect.height()),
                    Qt::AlignVCenter | Qt::AlignRight, lineLabel);
            }

            std::optional<std::string> textOpt = leftSide ? row.left : row.right;
            if (!leftSide && kind == algorithms::DiffRowKind::Context && !textOpt) {
                textOpt = row.left;
            }
            const auto textX = x + kLineNumberWidth + kMarkerWidth + kTextPad;
            const auto textWidth = paneWidth - kLineNumberWidth - kMarkerWidth - kTextPad - 4;
            if (textOpt && !textOpt->empty() && textWidth > 0) {
                std::optional<std::string_view> other;
                if (leftSide && row.right) other = std::string_view(*row.right);
                else if (!leftSide && row.left) other = std::string_view(*row.left);
                const auto ext = fileExtension_.toUtf8();
                paintStyledDiffText(
                    painter,
                    metrics,
                    QRect(textX, rowRect.top(), textWidth, rowRect.height()),
                    *textOpt,
                    std::string_view(ext.constData(), static_cast<std::size_t>(ext.size())),
                    leftSide,
                    kind == algorithms::DiffRowKind::Changed,
                    other);
            }
        }
    }

    void paintRibbons(QPainter& painter, int leftX, int rightX) {
        for (const auto& transition : layout_.transitions) {
            const auto leftTop = transition.leftRange.first;
            const auto leftBottom = transition.leftRange.second;
            const auto rightTop = transition.rightRange.first;
            const auto rightBottom = transition.rightRange.second;

            if (transition.isAddition()) {
                QPen pen(QColor(71, 184, 99, 140));
                pen.setWidthF(1.0);
                painter.setPen(pen);
                painter.drawLine(QPointF(4, leftTop), QPointF(leftX, leftTop));
            } else if (transition.isRemoval()) {
                QPen pen(QColor(235, 84, 84, 140));
                pen.setWidthF(1.0);
                painter.setPen(pen);
                painter.drawLine(QPointF(rightX, rightTop),
                                 QPointF(width() - 4, rightTop));
            }

            const auto ctrl1 = leftX + (rightX - leftX) * 0.42;
            const auto ctrl2 = leftX + (rightX - leftX) * 0.58;
            QPainterPath path;
            path.moveTo(leftX, leftTop);
            path.cubicTo(ctrl1, leftTop, ctrl2, rightTop, rightX, rightTop);
            path.lineTo(rightX, rightBottom);
            path.cubicTo(ctrl2, rightBottom, ctrl1, leftBottom, leftX, leftBottom);
            path.closeSubpath();
            painter.setPen(QPen(ribbonStroke(transition), 1.0, Qt::SolidLine, Qt::RoundCap,
                                Qt::RoundJoin));
            painter.setBrush(ribbonFill(transition));
            painter.drawPath(path);

            QString glyph = QStringLiteral("↔");
            if (transition.isAddition()) glyph = QStringLiteral("›");
            else if (transition.isRemoval()) glyph = QStringLiteral("‹");
            double markerY = (leftTop + leftBottom + rightTop + rightBottom) / 4.0;
            if (transition.isAddition()) markerY = leftTop;
            else if (transition.isRemoval()) markerY = rightTop;
            painter.setPen(ribbonStroke(transition).lighter(120));
            QFont glyphFont = font();
            glyphFont.setPointSize(8);
            glyphFont.setBold(true);
            painter.setFont(glyphFont);
            painter.drawText(
                QRectF(leftX, markerY - 7, rightX - leftX, 14),
                Qt::AlignCenter, glyph);
        }
    }

    DiffSplitWidget* owner_ = nullptr;
    algorithms::DiffSplitLayout layout_;
    std::vector<algorithms::DiffDisplayRow> displayRows_;
    QString selectedHunkId_;
    QString fileExtension_;
};

DiffSplitWidget::DiffSplitWidget(QWidget* parent) : QWidget(parent) {
    setObjectName(QStringLiteral("DiffSplitWidget"));
    setStyleSheet(QStringLiteral(
        "DiffSplitWidget {"
        "  background-color: %1;"
        "}"
        "DiffSplitWidget QPushButton[secondaryAction=\"true\"] {"
        "  background-color: transparent;"
        "  border: 1px solid %2;"
        "  border-radius: 5px;"
        "  color: %3;"
        "  padding: 3px 10px;"
        "  min-height: 26px;"
        "  font-size: 11.5px;"
        "  font-weight: 500;"
        "}"
        "DiffSplitWidget QPushButton[secondaryAction=\"true\"]:hover {"
        "  background-color: rgba(255, 255, 255, 12);"
        "}"
        "DiffSplitWidget QPushButton[primaryAction=\"true\"] {"
        "  background-color: %4;"
        "  border: 1px solid %4;"
        "  border-radius: 5px;"
        "  color: white;"
        "  padding: 3px 10px;"
        "  min-height: 26px;"
        "  font-size: 11.5px;"
        "  font-weight: 600;"
        "}"
        "DiffSplitWidget QToolButton {"
        "  background: transparent;"
        "  border: none;"
        "  border-radius: 5px;"
        "  color: %5;"
        "  font-size: 13px;"
        "}"
        "DiffSplitWidget QToolButton:hover {"
        "  background-color: rgba(255, 255, 255, 14);"
        "  color: %3;"
        "}"
        "DiffSplitWidget QToolButton:disabled {"
        "  color: rgba(255, 255, 255, 40);"
        "}")
                      .arg(ui::Theme::rgba(ui::Theme::editor()),
                           ui::Theme::rgba(ui::Theme::inputBorder()),
                           ui::Theme::rgba(ui::Theme::primaryText()),
                           ui::Theme::rgba(ui::Theme::accent()),
                           ui::Theme::rgba(ui::Theme::secondaryText())));

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    tabChrome_ = new QWidget(this);
    tabChrome_->setStyleSheet(QStringLiteral(
        "background-color: %1;").arg(ui::Theme::rgba(ui::Theme::sidebar())));
    auto* tabLayout = new QHBoxLayout(tabChrome_);
    tabLayout->setContentsMargins(12, 0, 6, 0);
    tabLayout->setSpacing(7);
    auto* fileIcon = new QLabel(tabChrome_);
    fileIcon->setPixmap(ui::IdeaIcons::pixmap(QStringLiteral("fileTypes/text.svg"), 14,
                                              ui::Theme::secondaryText()));
    fileIcon->setFixedSize(16, 16);
    fileNameLabel_ = new QLabel(tabChrome_);
    fileNameLabel_->setStyleSheet(
        QStringLiteral("color: %1; font-weight: 600; font-size: 12.5px;")
            .arg(ui::Theme::rgba(ui::Theme::primaryText())));
    statusBadgeLabel_ = makeBadge(tabChrome_, ui::Theme::warning());
    modeBadgeLabel_ = makeBadge(tabChrome_, ui::Theme::accent());
    tabLayout->addWidget(fileIcon);
    tabLayout->addWidget(fileNameLabel_);
    tabLayout->addWidget(statusBadgeLabel_);
    tabLayout->addWidget(modeBadgeLabel_);
    tabLayout->addStretch(1);
    closeButton_ = ui::makeIconButton(tabChrome_, QStringLiteral("Close diff"),
                                      QStringLiteral("close"));
    tabLayout->addWidget(closeButton_);
    tabChrome_->setFixedHeight(34);
    root->addWidget(tabChrome_);

    auto* accent = new QFrame(this);
    accent->setFixedHeight(2);
    accent->setStyleSheet(
        QStringLiteral("background-color: %1; border: none;")
            .arg(ui::Theme::rgba(ui::Theme::accent())));
    root->addWidget(accent);

    commitBar_ = new QWidget(this);
    auto* commitLayout = new QHBoxLayout(commitBar_);
    commitLayout->setContentsMargins(12, 0, 12, 0);
    commitLayout->setSpacing(10);
    commitHashLabel_ = new QLabel(commitBar_);
    commitHashLabel_->setStyleSheet(QStringLiteral(
        "QLabel {"
        "  color: white;"
        "  background-color: %1;"
        "  border-radius: 4px;"
        "  padding: 2px 8px;"
        "  font-family: Cascadia Mono, Consolas, monospace;"
        "  font-size: 11px;"
        "  font-weight: 600;"
        "}").arg(ui::Theme::rgba(ui::Theme::accent())));
    commitSubjectLabel_ = new QLabel(commitBar_);
    commitSubjectLabel_->setStyleSheet(
        QStringLiteral("color: %1; font-size: 12px;")
            .arg(ui::Theme::rgba(ui::Theme::primaryText())));
    commitLayout->addWidget(commitHashLabel_);
    commitLayout->addWidget(commitSubjectLabel_, 1);
    auto* readOnlyChip = makeToolbarChip(commitBar_, QStringLiteral("Read only"));
    commitLayout->addWidget(readOnlyChip);
    commitBar_->setFixedHeight(34);
    commitBar_->setStyleSheet(
        QStringLiteral("background-color: rgba(40, 70, 120, 70);"));
    commitBar_->setVisible(false);
    root->addWidget(commitBar_);

    toolbar_ = new QWidget(this);
    ui::applyToolHeaderBackground(toolbar_);
    auto* toolbarLayout = new QHBoxLayout(toolbar_);
    toolbarLayout->setContentsMargins(8, 0, 10, 0);
    toolbarLayout->setSpacing(4);
    prevDiffButton_ = ui::makeIconButton(toolbar_, QStringLiteral("Previous difference"),
                                         QStringLiteral("up"));
    nextDiffButton_ = ui::makeIconButton(toolbar_, QStringLiteral("Next difference"),
                                         QStringLiteral("down"));
    toolbarLayout->addWidget(prevDiffButton_);
    toolbarLayout->addWidget(nextDiffButton_);
    toolbarLayout->addSpacing(6);

    auto* sideBySideChip = makeToolbarChip(toolbar_, QStringLiteral("▦  Side-by-side"));
    toolbarLayout->addWidget(sideBySideChip);
    toolbarLayout->addSpacing(4);

    differenceCountLabel_ = new QLabel(QStringLiteral("0 differences"), toolbar_);
    differenceCountLabel_->setStyleSheet(
        QStringLiteral("color: %1; font-size: 11.5px; font-weight: 500; padding: 0 6px;")
            .arg(ui::Theme::rgba(ui::Theme::primaryText())));
    toolbarLayout->addWidget(differenceCountLabel_);
    toolbarLayout->addSpacing(8);

    stageHunkButton_ = new QPushButton(QStringLiteral("Stage hunk"), toolbar_);
    unstageHunkButton_ = new QPushButton(QStringLiteral("Unstage hunk"), toolbar_);
    discardHunkButton_ = new QPushButton(QStringLiteral("Discard hunk"), toolbar_);
    stageHunkButton_->setProperty("primaryAction", true);
    unstageHunkButton_->setProperty("secondaryAction", true);
    discardHunkButton_->setProperty("secondaryAction", true);
    toolbarLayout->addWidget(stageHunkButton_);
    toolbarLayout->addWidget(unstageHunkButton_);
    toolbarLayout->addWidget(discardHunkButton_);
    toolbarLayout->addStretch(1);

    pathHintLabel_ = new QLabel(toolbar_);
    pathHintLabel_->setStyleSheet(
        QStringLiteral("color: %1; font-size: 11.5px;")
            .arg(ui::Theme::rgba(ui::Theme::secondaryText())));
    pathHintLabel_->setMaximumWidth(320);
    toolbarLayout->addWidget(pathHintLabel_);

    toolbar_->setFixedHeight(40);
    root->addWidget(toolbar_);
    root->addWidget(ui::makeDivider(this));

    versionHeader_ = new QWidget(this);
    versionHeader_->setStyleSheet(
        QStringLiteral("background-color: %1;")
            .arg(ui::Theme::rgba(ui::Theme::toolHeader())));
    auto* headerLayout = new QHBoxLayout(versionHeader_);
    headerLayout->setContentsMargins(0, 0, 0, 0);
    headerLayout->setSpacing(0);

    auto makeVersionPane = [&](QLabel*& title, QLabel*& path, const QString& defaultTitle) {
        auto* pane = new QWidget(versionHeader_);
        auto* layout = new QVBoxLayout(pane);
        layout->setContentsMargins(12, 5, 12, 5);
        layout->setSpacing(1);
        title = new QLabel(defaultTitle, pane);
        title->setStyleSheet(
            QStringLiteral("color: %1; font-weight: 600; font-size: 11.5px;")
                .arg(ui::Theme::rgba(ui::Theme::primaryText())));
        path = new QLabel(pane);
        path->setStyleSheet(
            QStringLiteral("color: %1; font-size: 11px;")
                .arg(ui::Theme::rgba(ui::Theme::secondaryText())));
        path->setTextInteractionFlags(Qt::TextSelectableByMouse);
        layout->addWidget(title);
        layout->addWidget(path);
        return pane;
    };

    headerLayout->addWidget(
        makeVersionPane(leftVersionTitle_, leftVersionPath_,
                        QStringLiteral("Repository version")),
        1);

    auto* gutterSpacer = new QWidget(versionHeader_);
    gutterSpacer->setFixedWidth(kGutterWidth);
    gutterSpacer->setStyleSheet(
        QStringLiteral("background-color: %1;").arg(ui::Theme::rgba(ui::Theme::sidebar())));
    headerLayout->addWidget(gutterSpacer);

    headerLayout->addWidget(
        makeVersionPane(rightVersionTitle_, rightVersionPath_,
                        QStringLiteral("Local changes")),
        1);

    versionHeader_->setFixedHeight(42);
    root->addWidget(versionHeader_);
    root->addWidget(ui::makeDivider(this));

    scroll_ = new QScrollArea(this);
    scroll_->setWidgetResizable(false);
    scroll_->setFrameShape(QFrame::NoFrame);
    scroll_->setHorizontalScrollBarPolicy(Qt::ScrollBarAsNeeded);
    scroll_->setVerticalScrollBarPolicy(Qt::ScrollBarAsNeeded);
    scroll_->setStyleSheet(QStringLiteral(
        "QScrollArea { background: %1; border: none; }"
        "QScrollBar:vertical {"
        "  background: %1; width: 10px; margin: 0;"
        "}"
        "QScrollBar::handle:vertical {"
        "  background: rgba(255,255,255,40); border-radius: 4px; min-height: 24px;"
        "}"
        "QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }"
    ).arg(ui::Theme::rgba(ui::Theme::editor())));
    canvas_ = new Canvas(this);
    scroll_->setWidget(canvas_);
    root->addWidget(scroll_, 1);

    connect(closeButton_, &QToolButton::clicked, this, &DiffSplitWidget::closeRequested);
    connect(prevDiffButton_, &QToolButton::clicked, this, [this] { navigateDifference(-1); });
    connect(nextDiffButton_, &QToolButton::clicked, this, [this] { navigateDifference(1); });
    connect(stageHunkButton_, &QPushButton::clicked, this, &DiffSplitWidget::stageHunkRequested);
    connect(unstageHunkButton_, &QPushButton::clicked, this, &DiffSplitWidget::unstageHunkRequested);
    connect(discardHunkButton_, &QPushButton::clicked, this, &DiffSplitWidget::discardHunkRequested);

    setMinimumHeight(280);
    updateNavigateButtons();
}

void DiffSplitWidget::clear() {
    displayRows_.clear();
    kinds_.clear();
    layout_ = {};
    selectedHunkId_.clear();
    differenceHunkIds_.clear();
    differenceIndex_ = -1;
    fileExtension_.clear();
    if (canvas_ != nullptr) canvas_->setLayoutData({}, {}, {}, {});
    leftVersionPath_->clear();
    rightVersionPath_->clear();
    fileNameLabel_->clear();
    statusBadgeLabel_->setVisible(false);
    modeBadgeLabel_->setVisible(false);
    commitBar_->setVisible(false);
    if (pathHintLabel_ != nullptr) pathHintLabel_->clear();
    if (differenceCountLabel_ != nullptr) {
        differenceCountLabel_->setText(QStringLiteral("0 differences"));
    }
    updateNavigateButtons();
}

void DiffSplitWidget::setFileChrome(const QString& fileName,
                                    const QString& statusBadge,
                                    const QString& modeBadge) {
    fileNameLabel_->setText(fileName);
    const auto slash = std::max(fileName.lastIndexOf(QLatin1Char('/')),
                                fileName.lastIndexOf(QLatin1Char('\\')));
    const auto base = slash >= 0 ? fileName.mid(slash + 1) : fileName;
    const auto dot = base.lastIndexOf(QLatin1Char('.'));
    fileExtension_ = dot >= 0 ? base.mid(dot + 1).toLower() : QString();
    if (canvas_ != nullptr) {
        canvas_->setLayoutData(layout_, displayRows_, selectedHunkId_, fileExtension_);
    }
    statusBadgeLabel_->setText(statusBadge);
    statusBadgeLabel_->setVisible(!statusBadge.isEmpty());
    modeBadgeLabel_->setText(modeBadge);
    modeBadgeLabel_->setVisible(!modeBadge.isEmpty());

    QColor statusColor = ui::Theme::warning();
    const auto upper = statusBadge.toUpper();
    if (upper.contains(QStringLiteral("ADD")) || upper == QStringLiteral("A")) {
        statusColor = ui::Theme::success();
    } else if (upper.contains(QStringLiteral("DEL")) || upper == QStringLiteral("D")) {
        statusColor = ui::Theme::error();
    } else if (upper.contains(QStringLiteral("CONFLICT"))) {
        statusColor = ui::Theme::error();
    }
    statusBadgeLabel_->setStyleSheet(QStringLiteral(
        "QLabel {"
        "  color: %1;"
        "  background-color: %2;"
        "  border-radius: 4px;"
        "  padding: 0 7px;"
        "  font-size: 9px;"
        "  font-weight: 700;"
        "  letter-spacing: 0.04em;"
        "}")
                                         .arg(ui::Theme::rgba(statusColor),
                                              ui::Theme::rgba(QColor(statusColor.red(),
                                                                     statusColor.green(),
                                                                     statusColor.blue(),
                                                                     28))));

    QColor modeColor = ui::Theme::accent();
    if (modeBadge.toUpper().contains(QStringLiteral("STAGED"))) {
        modeColor = ui::Theme::success();
    } else if (modeBadge.toUpper().contains(QStringLiteral("WORKING"))) {
        modeColor = ui::Theme::warning();
    } else if (modeBadge.toUpper().contains(QStringLiteral("DIFF"))) {
        modeColor = ui::Theme::accent();
    }
    modeBadgeLabel_->setStyleSheet(QStringLiteral(
        "QLabel {"
        "  color: %1;"
        "  background-color: %2;"
        "  border-radius: 4px;"
        "  padding: 0 7px;"
        "  font-size: 9px;"
        "  font-weight: 700;"
        "  letter-spacing: 0.04em;"
        "}")
                                       .arg(ui::Theme::rgba(modeColor),
                                            ui::Theme::rgba(QColor(modeColor.red(),
                                                                   modeColor.green(),
                                                                   modeColor.blue(),
                                                                   28))));
}

void DiffSplitWidget::setCommitContext(const QString& shortHash, const QString& subject) {
    const bool visible = !shortHash.isEmpty();
    commitBar_->setVisible(visible);
    commitHashLabel_->setText(shortHash);
    commitSubjectLabel_->setText(subject);
}

void DiffSplitWidget::setVersionTitles(const QString& leftTitle,
                                       const QString& leftPath,
                                       const QString& rightTitle,
                                       const QString& rightPath) {
    leftVersionTitle_->setText(leftTitle);
    leftVersionPath_->setText(leftPath);
    rightVersionTitle_->setText(rightTitle);
    rightVersionPath_->setText(rightPath);
    if (pathHintLabel_ != nullptr) {
        pathHintLabel_->setText(rightPath.isEmpty() ? leftPath : rightPath);
        pathHintLabel_->setToolTip(pathHintLabel_->text());
    }
}

void DiffSplitWidget::setHunkActionsVisible(bool visible) {
    stageHunkButton_->setVisible(visible);
    unstageHunkButton_->setVisible(visible);
    discardHunkButton_->setVisible(visible);
}

void DiffSplitWidget::setSelectedHunkId(const QString& hunkId) {
    selectedHunkId_ = hunkId;
    differenceIndex_ = differenceHunkIds_.indexOf(hunkId);
    if (canvas_ != nullptr) {
        canvas_->setLayoutData(layout_, displayRows_, selectedHunkId_, fileExtension_);
    }
    updateNavigateButtons();
}

QString DiffSplitWidget::selectedHunkId() const {
    return selectedHunkId_;
}

void DiffSplitWidget::scrollToHunk(const QString& hunkId) {
    if (canvas_ == nullptr || scroll_ == nullptr || hunkId.isEmpty()) return;
    setSelectedHunkId(hunkId);
    const auto y = static_cast<int>(canvas_->scrollYForHunk(hunkId));
    scroll_->verticalScrollBar()->setValue(std::max(0, y - 40));
}

void DiffSplitWidget::navigateDifference(int delta) {
    if (differenceHunkIds_.isEmpty()) return;
    if (differenceIndex_ < 0) differenceIndex_ = 0;
    else differenceIndex_ = (differenceIndex_ + delta + differenceHunkIds_.size()) %
        differenceHunkIds_.size();
    scrollToHunk(differenceHunkIds_.at(differenceIndex_));
    emit hunkSelected(selectedHunkId_);
}

void DiffSplitWidget::notifyHunkSelected(const QString& hunkId) {
    selectedHunkId_ = hunkId;
    differenceIndex_ = differenceHunkIds_.indexOf(hunkId);
    updateNavigateButtons();
    emit hunkSelected(hunkId);
}

void DiffSplitWidget::notifyExpandRegion(const QString& regionId) {
    emit expandRegionRequested(regionId);
}

void DiffSplitWidget::setDiff(const std::vector<algorithms::DiffRow>& rows,
                             const std::unordered_set<std::string>& expandedRegionIDs) {
    displayRows_ = algorithms::DiffCollapse::plan(rows, expandedRegionIDs);
    kinds_.clear();
    kinds_.reserve(displayRows_.size());
    for (const auto& display : displayRows_) {
        if (display.isCollapsed()) {
            kinds_.push_back(algorithms::DiffRowKind::Information);
        } else {
            kinds_.push_back(display.row().kind);
        }
    }
    rebuildLayout();
    collectDifferenceHunks();
    updateNavigateButtons();
}

void DiffSplitWidget::collectDifferenceHunks() {
    differenceHunkIds_.clear();
    QSet<QString> seen;
    for (const auto& display : displayRows_) {
        if (display.isCollapsed()) continue;
        const auto& row = display.row();
        if (row.hunkId.empty()) continue;
        if (row.kind != algorithms::DiffRowKind::Changed &&
            row.kind != algorithms::DiffRowKind::Addition &&
            row.kind != algorithms::DiffRowKind::Removal) {
            continue;
        }
        const auto id = fromUtf8(row.hunkId);
        if (seen.contains(id)) continue;
        seen.insert(id);
        differenceHunkIds_.push_back(id);
    }
    differenceIndex_ = differenceHunkIds_.indexOf(selectedHunkId_);
}

void DiffSplitWidget::updateNavigateButtons() {
    const bool has = !differenceHunkIds_.isEmpty();
    prevDiffButton_->setEnabled(has);
    nextDiffButton_->setEnabled(has);
    if (differenceCountLabel_ != nullptr) {
        const auto count = differenceHunkIds_.size();
        differenceCountLabel_->setText(
            count == 1 ? QStringLiteral("1 difference")
                       : QStringLiteral("%1 differences").arg(count));
    }
}

void DiffSplitWidget::rebuildLayout() {
    layout_ = algorithms::planDiffSplitLayout(
        displayRows_, kinds_, kRowHeight, kInfoRowHeight);
    if (canvas_ != nullptr) {
        canvas_->setLayoutData(layout_, displayRows_, selectedHunkId_, fileExtension_);
        syncScrollExtents();
    }
}

void DiffSplitWidget::syncScrollExtents() {
    if (canvas_ == nullptr || scroll_ == nullptr) return;
    const auto viewportWidth = scroll_->viewport()->width();
    canvas_->setFixedWidth(std::max(viewportWidth, 200));
    canvas_->setMinimumHeight(
        static_cast<int>(std::ceil(std::max(layout_.contentHeight(), 120.0))));
}

void DiffSplitWidget::resizeEvent(QResizeEvent* event) {
    QWidget::resizeEvent(event);
    syncScrollExtents();
}

} // namespace lithe::windows
