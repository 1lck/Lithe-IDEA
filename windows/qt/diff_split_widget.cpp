#include "diff_split_widget.h"

#include "workbench_ui_theme.h"

#include <QFont>
#include <QFontMetrics>
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

namespace lithe::windows {
namespace {

constexpr int kRowHeight = 22;
constexpr int kInfoRowHeight = 26;
constexpr int kLineNumberWidth = 48;
constexpr int kMarkerWidth = 3;
constexpr int kGutterWidth = 40;
constexpr int kTextPad = 8;

QColor rowBackground(algorithms::DiffRowKind kind, bool leftSide) {
    using K = algorithms::DiffRowKind;
    switch (kind) {
    case K::Changed:
        return leftSide ? QColor(180, 70, 70, 56) : QColor(70, 160, 95, 62);
    case K::Removal:
        return leftSide ? QColor(180, 70, 70, 70) : QColor(0, 0, 0, 0);
    case K::Addition:
        return leftSide ? QColor(0, 0, 0, 0) : QColor(70, 160, 95, 70);
    case K::Information:
        return QColor(36, 48, 64);
    case K::Context:
        return QColor(0, 0, 0, 0);
    }
    return QColor(0, 0, 0, 0);
}

QColor markerColor(algorithms::DiffRowKind kind, bool leftSide) {
    using K = algorithms::DiffRowKind;
    switch (kind) {
    case K::Changed:
        return leftSide ? QColor(214, 75, 75, 180) : QColor(67, 160, 93, 180);
    case K::Removal:
        return leftSide ? QColor(214, 75, 75, 200) : QColor(0, 0, 0, 0);
    case K::Addition:
        return leftSide ? QColor(0, 0, 0, 0) : QColor(67, 160, 93, 200);
    default:
        return QColor(0, 0, 0, 0);
    }
}

QColor ribbonColor(const algorithms::DiffTransition& transition) {
    if (transition.isRemoval()) return QColor(214, 75, 75, 55);
    return QColor(67, 160, 93, 55);
}

QColor ribbonStroke(const algorithms::DiffTransition& transition) {
    if (transition.isRemoval()) return QColor(214, 75, 75, 150);
    return QColor(67, 160, 93, 150);
}

QString fromUtf8(std::string_view value) {
    return QString::fromUtf8(value.data(), static_cast<qsizetype>(value.size()));
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
        "  padding: 0 6px;"
        "  font-size: 9px;"
        "  font-weight: 700;"
        "}")
                             .arg(ui::Theme::rgba(color),
                                  ui::Theme::rgba(QColor(color.red(), color.green(),
                                                         color.blue(), 36))));
    badge->setVisible(false);
    return badge;
}

} // namespace

class DiffSplitWidget::Canvas final : public QWidget {
public:
    explicit Canvas(DiffSplitWidget* owner) : QWidget(owner), owner_(owner) {
        setMouseTracking(true);
        QFont font(QStringLiteral("Consolas"));
        font.setStyleHint(QFont::Monospace);
        font.setPointSize(10);
        setFont(font);
        setAutoFillBackground(true);
        QPalette pal = palette();
        pal.setColor(QPalette::Window, ui::Theme::editor());
        setPalette(pal);
    }

    void setLayoutData(algorithms::DiffSplitLayout layout,
                       std::vector<algorithms::DiffDisplayRow> displayRows,
                       const QString& selectedHunkId) {
        layout_ = std::move(layout);
        displayRows_ = std::move(displayRows);
        selectedHunkId_ = selectedHunkId;
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

        painter.fillRect(QRect(gutterStart, 0, kGutterWidth, height()), ui::Theme::sidebar());
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
                painter.fillRect(rowRect, QColor(36, 48, 64));
                painter.setPen(QColor(128, 170, 220));
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
                             QColor(19, 20, 22, 160));
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
            }

            painter.setFont(mono);
            const auto lineNo = leftSide ? row.oldLine : row.newLine;
            QString lineLabel;
            if (kind == algorithms::DiffRowKind::Addition && !leftSide) {
                lineLabel = QStringLiteral("+");
                painter.setPen(QColor(67, 160, 93, 220));
            } else if (kind == algorithms::DiffRowKind::Removal && leftSide) {
                lineLabel = QStringLiteral("-");
                painter.setPen(QColor(214, 75, 75, 220));
            } else {
                painter.setPen(ui::Theme::secondaryText());
            }
            if (lineNo) {
                lineLabel += QString::number(static_cast<qulonglong>(*lineNo));
            }
            if (!lineLabel.isEmpty()) {
                painter.drawText(
                    QRect(x, rowRect.top(), kLineNumberWidth - 4, rowRect.height()),
                    Qt::AlignVCenter | Qt::AlignRight, lineLabel);
            }

            std::optional<std::string> textOpt = leftSide ? row.left : row.right;
            if (!leftSide && kind == algorithms::DiffRowKind::Context && !textOpt) {
                textOpt = row.left;
            }
            const QString text = textOpt ? fromUtf8(*textOpt) : QString();
            painter.setPen(ui::Theme::primaryText());
            const auto textX = x + kLineNumberWidth + kMarkerWidth + kTextPad;
            const auto textWidth = paneWidth - kLineNumberWidth - kMarkerWidth - kTextPad - 4;
            painter.drawText(
                QRect(textX, rowRect.top(), std::max(0, textWidth), rowRect.height()),
                Qt::AlignVCenter | Qt::AlignLeft,
                metrics.elidedText(text, Qt::ElideRight, std::max(0, textWidth)));
        }
    }

    void paintRibbons(QPainter& painter, int leftX, int rightX) {
        for (const auto& transition : layout_.transitions) {
            const auto leftTop = transition.leftRange.first;
            const auto leftBottom = transition.leftRange.second;
            const auto rightTop = transition.rightRange.first;
            const auto rightBottom = transition.rightRange.second;

            if (transition.isAddition()) {
                painter.setPen(QPen(QColor(67, 160, 93, 160), 1));
                painter.drawLine(QPointF(4, leftTop), QPointF(leftX, leftTop));
            } else if (transition.isRemoval()) {
                painter.setPen(QPen(QColor(214, 75, 75, 160), 1));
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
            painter.setPen(QPen(ribbonStroke(transition), 1));
            painter.setBrush(ribbonColor(transition));
            painter.drawPath(path);

            QString glyph = QStringLiteral("↔");
            if (transition.isAddition()) glyph = QStringLiteral("›");
            else if (transition.isRemoval()) glyph = QStringLiteral("‹");
            double markerY = (leftTop + leftBottom + rightTop + rightBottom) / 4.0;
            if (transition.isAddition()) markerY = leftTop;
            else if (transition.isRemoval()) markerY = rightTop;
            painter.setPen(ribbonStroke(transition));
            painter.drawText(
                QRectF(leftX, markerY - 7, rightX - leftX, 14),
                Qt::AlignCenter, glyph);
        }
    }

    DiffSplitWidget* owner_ = nullptr;
    algorithms::DiffSplitLayout layout_;
    std::vector<algorithms::DiffDisplayRow> displayRows_;
    QString selectedHunkId_;
};

DiffSplitWidget::DiffSplitWidget(QWidget* parent) : QWidget(parent) {
    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    tabChrome_ = new QWidget(this);
    ui::applyToolHeaderBackground(tabChrome_);
    auto* tabLayout = new QHBoxLayout(tabChrome_);
    tabLayout->setContentsMargins(12, 0, 6, 0);
    tabLayout->setSpacing(7);
    fileNameLabel_ = new QLabel(tabChrome_);
    fileNameLabel_->setStyleSheet(
        QStringLiteral("color: %1; font-weight: 600;")
            .arg(ui::Theme::rgba(ui::Theme::primaryText())));
    statusBadgeLabel_ = makeBadge(tabChrome_, ui::Theme::warning());
    modeBadgeLabel_ = makeBadge(tabChrome_, ui::Theme::accent());
    tabLayout->addWidget(fileNameLabel_);
    tabLayout->addWidget(statusBadgeLabel_);
    tabLayout->addWidget(modeBadgeLabel_);
    tabLayout->addStretch(1);
    closeButton_ = ui::makeIconButton(tabChrome_, QStringLiteral("Close diff"),
                                      QStringLiteral("✕"));
    tabLayout->addWidget(closeButton_);
    tabChrome_->setFixedHeight(34);
    root->addWidget(tabChrome_);
    root->addWidget(ui::makeDivider(this));

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
        "  font-family: Consolas, monospace;"
        "  font-size: 11px;"
        "  font-weight: 600;"
        "}").arg(ui::Theme::rgba(ui::Theme::accent())));
    commitSubjectLabel_ = new QLabel(commitBar_);
    commitSubjectLabel_->setStyleSheet(
        QStringLiteral("color: %1;").arg(ui::Theme::rgba(ui::Theme::primaryText())));
    commitLayout->addWidget(commitHashLabel_);
    commitLayout->addWidget(commitSubjectLabel_, 1);
    commitBar_->setFixedHeight(32);
    commitBar_->setStyleSheet(
        QStringLiteral("background-color: %1;")
            .arg(ui::Theme::rgba(QColor(40, 70, 120, 90))));
    commitBar_->setVisible(false);
    root->addWidget(commitBar_);

    toolbar_ = new QWidget(this);
    ui::applyToolHeaderBackground(toolbar_);
    auto* toolbarLayout = new QHBoxLayout(toolbar_);
    toolbarLayout->setContentsMargins(8, 0, 8, 0);
    toolbarLayout->setSpacing(4);
    prevDiffButton_ = ui::makeIconButton(toolbar_, QStringLiteral("Previous difference"),
                                         QStringLiteral("↑"));
    nextDiffButton_ = ui::makeIconButton(toolbar_, QStringLiteral("Next difference"),
                                         QStringLiteral("↓"));
    stageHunkButton_ = new QPushButton(QStringLiteral("Stage hunk"), toolbar_);
    unstageHunkButton_ = new QPushButton(QStringLiteral("Unstage hunk"), toolbar_);
    discardHunkButton_ = new QPushButton(QStringLiteral("Discard hunk"), toolbar_);
    for (auto* button : {stageHunkButton_, unstageHunkButton_, discardHunkButton_}) {
        button->setProperty("secondaryAction", true);
    }
    toolbarLayout->addWidget(prevDiffButton_);
    toolbarLayout->addWidget(nextDiffButton_);
    toolbarLayout->addSpacing(8);
    toolbarLayout->addWidget(stageHunkButton_);
    toolbarLayout->addWidget(unstageHunkButton_);
    toolbarLayout->addWidget(discardHunkButton_);
    toolbarLayout->addStretch(1);
    toolbar_->setFixedHeight(34);
    root->addWidget(toolbar_);
    root->addWidget(ui::makeDivider(this));

    versionHeader_ = new QWidget(this);
    ui::applyToolHeaderBackground(versionHeader_);
    auto* headerLayout = new QHBoxLayout(versionHeader_);
    headerLayout->setContentsMargins(0, 0, 0, 0);
    headerLayout->setSpacing(0);

    auto* leftHeader = new QWidget(versionHeader_);
    auto* leftHeaderLayout = new QHBoxLayout(leftHeader);
    leftHeaderLayout->setContentsMargins(10, 0, 10, 0);
    leftHeaderLayout->setSpacing(7);
    leftVersionTitle_ = new QLabel(QStringLiteral("Repository version"), leftHeader);
    leftVersionTitle_->setStyleSheet(
        QStringLiteral("color: %1; font-weight: 600;")
            .arg(ui::Theme::rgba(ui::Theme::primaryText())));
    leftVersionPath_ = new QLabel(leftHeader);
    leftVersionPath_->setStyleSheet(
        QStringLiteral("color: %1;").arg(ui::Theme::rgba(ui::Theme::secondaryText())));
    leftHeaderLayout->addWidget(leftVersionTitle_);
    leftHeaderLayout->addWidget(leftVersionPath_, 1);
    headerLayout->addWidget(leftHeader, 1);

    auto* gutterSpacer = new QWidget(versionHeader_);
    gutterSpacer->setFixedWidth(kGutterWidth);
    gutterSpacer->setStyleSheet(
        QStringLiteral("background-color: %1;").arg(ui::Theme::rgba(ui::Theme::sidebar())));
    headerLayout->addWidget(gutterSpacer);

    auto* rightHeader = new QWidget(versionHeader_);
    auto* rightHeaderLayout = new QHBoxLayout(rightHeader);
    rightHeaderLayout->setContentsMargins(10, 0, 10, 0);
    rightHeaderLayout->setSpacing(7);
    rightVersionTitle_ = new QLabel(QStringLiteral("Local changes"), rightHeader);
    rightVersionTitle_->setStyleSheet(
        QStringLiteral("color: %1; font-weight: 600;")
            .arg(ui::Theme::rgba(ui::Theme::primaryText())));
    rightVersionPath_ = new QLabel(rightHeader);
    rightVersionPath_->setStyleSheet(
        QStringLiteral("color: %1;").arg(ui::Theme::rgba(ui::Theme::secondaryText())));
    rightHeaderLayout->addWidget(rightVersionTitle_);
    rightHeaderLayout->addWidget(rightVersionPath_, 1);
    headerLayout->addWidget(rightHeader, 1);

    versionHeader_->setFixedHeight(34);
    root->addWidget(versionHeader_);
    root->addWidget(ui::makeDivider(this));

    scroll_ = new QScrollArea(this);
    scroll_->setWidgetResizable(false);
    scroll_->setFrameShape(QFrame::NoFrame);
    scroll_->setHorizontalScrollBarPolicy(Qt::ScrollBarAsNeeded);
    scroll_->setVerticalScrollBarPolicy(Qt::ScrollBarAsNeeded);
    scroll_->setStyleSheet(QStringLiteral("QScrollArea { background: %1; border: none; }")
                               .arg(ui::Theme::rgba(ui::Theme::editor())));
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
    if (canvas_ != nullptr) canvas_->setLayoutData({}, {}, {});
    leftVersionPath_->clear();
    rightVersionPath_->clear();
    fileNameLabel_->clear();
    statusBadgeLabel_->setVisible(false);
    modeBadgeLabel_->setVisible(false);
    commitBar_->setVisible(false);
    updateNavigateButtons();
}

void DiffSplitWidget::setFileChrome(const QString& fileName,
                                    const QString& statusBadge,
                                    const QString& modeBadge) {
    fileNameLabel_->setText(fileName);
    statusBadgeLabel_->setText(statusBadge);
    statusBadgeLabel_->setVisible(!statusBadge.isEmpty());
    modeBadgeLabel_->setText(modeBadge);
    modeBadgeLabel_->setVisible(!modeBadge.isEmpty());
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
        canvas_->setLayoutData(layout_, displayRows_, selectedHunkId_);
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
}

void DiffSplitWidget::rebuildLayout() {
    layout_ = algorithms::planDiffSplitLayout(
        displayRows_, kinds_, kRowHeight, kInfoRowHeight);
    if (canvas_ != nullptr) {
        canvas_->setLayoutData(layout_, displayRows_, selectedHunkId_);
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
