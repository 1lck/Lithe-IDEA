#include "argument_tokenizer.h"
#include "diff_collapse.h"
#include "diff_pairing.h"
#include "diff_split_layout.h"
#include "diff_tokenizer.h"
#include "file_visibility_rules.h"
#include "fuzzy_match.h"
#include "git_graph_layout.h"
#include "git_reference_tree.h"
#include "gutter_hit_test.h"
#include "inline_diff.h"
#include "semver.h"
#include "syntax_highlighter.h"
#include "terminal_buffer.h"
#include "text_diff.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

using namespace lithe::windows::algorithms;

namespace {

DiffRow row(std::size_t sequence,
            DiffRowKind kind,
            std::optional<std::size_t> oldLine = std::nullopt,
            std::optional<std::size_t> newLine = std::nullopt,
            std::optional<std::string> left = std::nullopt,
            std::optional<std::string> right = std::nullopt) {
    return {oldLine, newLine, std::move(left), std::move(right), kind, "hunk-0", sequence};
}

bool hasToken(const std::vector<DiffToken>& tokens, DiffTokenKind kind, std::string_view text) {
    for (const auto& token : tokens) {
        if (token.kind == kind && token.text == text) return true;
    }
    return false;
}

bool hasSpan(const std::vector<SyntaxHighlightSpan>& spans,
             SyntaxHighlightKind kind,
             std::string_view source,
             std::string_view value) {
    for (const auto& span : spans) {
        if (span.kind == kind && source.substr(span.start, span.end - span.start) == value) return true;
    }
    return false;
}

void testDiffPairing() {
    assert(std::abs(DiffPairing::similarity("  return 1;  ", "return 1;") - 1.0) < 1e-9);
    const auto modified = DiffPairing::pairs({"old value"}, {"old values"});
    assert(modified.size() == 1 && modified.front().first == 0 && modified.front().second == 0);

    const auto single = DiffPairing::pairs({"left"}, {"completely different"});
    assert(single.size() == 1 && single.front().first == 0 && single.front().second == 0);

    std::vector<std::string> largeRemoved(65, "removed");
    std::vector<std::string> largeAdded(65, "added");
    const auto fallback = DiffPairing::pairs(largeRemoved, largeAdded);
    assert(fallback.size() == 65);
    assert(fallback.front().first == 0 && fallback.front().second == 0);
}

void testTextDiff() {
    const auto inserted = diffTextLines({"one", "two", "three"},
                                        {"one", "inserted", "two", "three"});
    assert(inserted.size() == 4);
    assert(inserted[0].kind == DiffRowKind::Context);
    assert(inserted[1].kind == DiffRowKind::Addition && !inserted[1].oldLine &&
           inserted[1].newLine == 2 && inserted[1].right == "inserted");
    assert(inserted[2].kind == DiffRowKind::Context && inserted[2].oldLine == 2 &&
           inserted[2].newLine == 3);
    assert(inserted[3].kind == DiffRowKind::Context);

    const auto removed = diffTextLines({"one", "removed", "two"}, {"one", "two"});
    assert(removed.size() == 3);
    assert(removed[1].kind == DiffRowKind::Removal && removed[1].oldLine == 2 &&
           !removed[1].newLine);
    assert(removed[2].kind == DiffRowKind::Context && removed[2].oldLine == 3 &&
           removed[2].newLine == 2);

    const auto changed = diffTextLines({"return oldValue;"}, {"return newValue;"});
    assert(changed.size() == 1 && changed[0].kind == DiffRowKind::Changed);
    assert(changed[0].left == "return oldValue;" && changed[0].right == "return newValue;");
    assert(changed[0].hunkId == "history-snapshot");

    const auto different = diffTextLines({"alpha", "beta"}, {"gamma", "delta"});
    assert(different.size() == 4);
    assert(std::count_if(different.begin(), different.end(), [](const auto& item) {
        return item.kind == DiffRowKind::Removal;
    }) == 2);
    assert(std::count_if(different.begin(), different.end(), [](const auto& item) {
        return item.kind == DiffRowKind::Addition;
    }) == 2);

    const auto unicode = diffTextLines({"你好，旧世界"}, {"你好，新世界"});
    assert(unicode.size() == 1 && unicode[0].kind == DiffRowKind::Changed);

    std::vector<std::string> largeOld(1'200, "same");
    std::vector<std::string> largeNew = largeOld;
    largeNew.insert(largeNew.begin() + 600, "middle");
    const auto large = diffTextLines(largeOld, largeNew);
    assert(large.size() == 1'201);
    assert(large[600].kind == DiffRowKind::Addition);
    assert(large[601].kind == DiffRowKind::Context && large[601].oldLine == 601 &&
           large[601].newLine == 602);
}

void testDiffCollapseAndSplitLayout() {
    std::vector<DiffRow> rows;
    for (std::size_t index = 0; index < 4; ++index) {
        rows.push_back(row(index, DiffRowKind::Context, index + 1, index + 1,
                           "context-" + std::to_string(index)));
    }
    rows.push_back(row(4, DiffRowKind::Changed, 5, 5, "old", "new"));
    for (std::size_t index = 5; index < 18; ++index) {
        rows.push_back(row(index, DiffRowKind::Context, index + 1, index + 1,
                           "context-" + std::to_string(index)));
    }
    rows.push_back(row(18, DiffRowKind::Addition, std::nullopt, 19, std::nullopt, "added"));

    const auto display = DiffCollapse::plan(rows, {}, {}, 4, 2);
    assert(display.size() == 4 + 1 + 2 + 1 + 2 + 1);
    assert(display[7].isCollapsed());
    assert(display[7].region().id == "collapsed-7-16");
    assert(display[7].region().hiddenRowCount() == 9);

    const auto expanded = DiffCollapse::plan(rows, {"collapsed-7-16"}, {}, 4, 2);
    assert(expanded.size() == rows.size());
    const auto pinnedRowID = DiffDisplayRow{rows[9], 9}.id();
    const auto pinned = DiffCollapse::plan(rows, {}, {pinnedRowID}, 4, 2);
    assert(pinned.size() == rows.size());

    std::vector<DiffDisplayRow> splitRows{
        {row(0, DiffRowKind::Context, 1, 1, "same") , 0},
        {row(1, DiffRowKind::Changed, 2, 2, "old", "new"), 1},
        {row(2, DiffRowKind::Addition, std::nullopt, 3, std::nullopt, "added"), 2},
        {row(3, DiffRowKind::Removal, 3, std::nullopt, "removed", std::nullopt), 3},
        {row(4, DiffRowKind::Information, std::nullopt, std::nullopt, "@@"), 4},
    };
    const auto layout = planDiffSplitLayout(
        splitRows,
        {DiffRowKind::Context, DiffRowKind::Changed, DiffRowKind::Addition,
         DiffRowKind::Removal, DiffRowKind::Information});
    assert(layout.leftHeight == 24 * 3 + 27);
    assert(layout.rightHeight == 24 * 3 + 27);
    assert(layout.leftItems.size() == 4);
    assert(layout.rightItems.size() == 4);
    assert(layout.rightItems[1].isScrollAnchor == false);
    assert(layout.rightItems[2].isScrollAnchor);
    assert(layout.transitions.size() == 3);
    assert(layout.transitions[1].isAddition());
    assert(layout.transitions[2].isRemoval());
}

void testInlineDiff() {
    const auto range = changedRange("prefix old suffix", std::string_view("prefix new suffix"));
    assert(range && range->start == 7 && range->end == 10);
    const auto unicode = changedRange("前甲后", std::string_view("前乙后"));
    assert(unicode && unicode->start == 1 && unicode->end == 2);
    assert(!changedRange("same", std::string_view("same")));
    assert(!changedRange("same", std::nullopt));
}

void testVisibilityRules() {
    FileVisibilityRules rules({"  generated  ", "TARGET"}, {"*.generated.java"});
    assert(rules.isHidden("C:/project/target/classes", "C:/project", true, true));
    assert(rules.isHidden("C:/project/src/../target/classes", "C:/project", true, false));
    assert(rules.isHidden("C:/project/src/.DS_Store", "C:/project", true, false));
    assert(rules.isHidden("C:/project/src/Main.generated.java", "C:/project", true, false));
    assert(rules.isHidden("C:/project/generated", "C:/project", true, true));
    assert(!rules.isHidden("C:/project/src/Main.java", "C:/project", true, false));
    assert(rules.isHiddenDirectoryName("TaRgEt"));
}

void testFuzzyMatch() {
    assert(fuzzySubsequenceMatch("Git History", "gthst"));
    assert(fuzzySubsequenceMatch("Replace in Project...", "RIP"));
    assert(fuzzySubsequenceMatch("本地历史", "本历"));
    assert(fuzzySubsequenceMatch("你好，新世界", "你世"));
    assert(!fuzzySubsequenceMatch("Git History", "history git"));
    assert(!fuzzySubsequenceMatch("本地历史", "历史本"));
    assert(fuzzySubsequenceMatch("anything", ""));
}

void testTerminalBuffer() {
    TerminalBuffer buffer;
    buffer.append("hello\nworld");
    assert(buffer.render(100) == "hello\nworld");
    buffer.reset();
    buffer.append("abc\x1b[2DXY");
    assert(buffer.render(100) == "aXY");
    buffer.reset();
    buffer.append("\x1b]0;ignored title\x07ok");
    assert(buffer.render(100) == "ok");
    buffer.reset();
    buffer.append("你好");
    assert(buffer.render(100) == "你好");
    buffer.reset();
    buffer.append("\x1b[999999999999Cdone");
    assert(buffer.render(5) == "done");
}

void testGitGraph() {
    const auto layout = layoutGitGraph({
        {"merge", {"feature", "root"}, "HEAD -> main", "Merge feature"},
        {"feature", {"root"}, "feature/orders", "Add feature"},
        {"root", {}, "", "Initial commit"},
    });
    assert(layout.rows.size() == 3);
    assert(layout.rows.front().parentEdges.size() == 2);
    assert(layout.rows.front().labels.size() == 2);
    assert(layout.rows.front().labels[0].kind == GitGraphReferenceKind::Head);
    assert(layout.rows.front().labels[0].title == "HEAD");
    assert(!layout.hasMissingParents);

    const auto missing = layoutGitGraph({{"tip", {"missing"}, "", "tip"}});
    assert(missing.hasMissingParents);
    assert(missing.rows.front().parentEdges.front().isMissing);
    assert(!missing.rows.front().parentEdges.front().targetLane);
}

void testGitReferenceTree() {
    const auto tree = buildGitReferenceTree({
        {"refs/heads/main", "main", "local", true, std::nullopt},
        {"refs/heads/feature/orders", "feature/orders", "local", false, std::nullopt},
        {"refs/heads/feature/api", "feature/api", "local", false, std::nullopt},
        {"refs/remotes/origin/main", "origin/main", "remote", false, std::string("main")},
    });
    assert(tree.size() == 3);
    assert(tree[0].name == "main");
    assert(tree[0].reference && tree[0].reference->isCurrent);
    assert(tree[1].name == "feature");
    assert(tree[1].children.size() == 2);
    assert(tree[1].children[0].name == "api");
    assert(tree[1].children[1].name == "orders");
}

void testSmallUtilities() {
    assert(isNewerVersion("v1.2.1", "1.2"));
    assert(!isNewerVersion("1.2.0-beta", "1.2"));
    assert(isNewerVersion("1.10", "1.9.9"));
    assert(!isNewerVersion("not-a-version", "1.0"));
    const auto components = parseVersionComponents(" 1..2 ");
    assert(components && *components == std::vector<int>({1, 2}));

    const auto arguments = tokenizeArguments(R"(-Dname="hello world" 'single quoted' plain\ value "a\"b" trailing\)");
    assert(arguments == std::vector<std::string>({
        "-Dname=hello world", "single quoted", "plain value", "a\"b", "trailing\\"}));

    const auto diffTokens = tokenizeDiffText(R"(return Foo(42, "x"); // comment)", "java");
    assert(hasToken(diffTokens, DiffTokenKind::Keyword, "return"));
    assert(hasToken(diffTokens, DiffTokenKind::Type, "Foo"));
    assert(hasToken(diffTokens, DiffTokenKind::Number, "42"));
    assert(hasToken(diffTokens, DiffTokenKind::String, "\"x\""));
    assert(hasToken(diffTokens, DiffTokenKind::Comment, "// comment"));
    assert(tokenizeDiffText("  # Heading", "md").front().kind == DiffTokenKind::Comment);
    assert(hasToken(tokenizeDiffText("<div>x</div>", "xml"), DiffTokenKind::Tag, "<div>"));

    const std::string source = "class Foo { int n = 42; // return\n@Anno }";
    const auto spans = highlightSyntax(source);
    assert(hasSpan(spans, SyntaxHighlightKind::Keyword, source, "class"));
    assert(hasSpan(spans, SyntaxHighlightKind::Type, source, "Foo"));
    assert(hasSpan(spans, SyntaxHighlightKind::Number, source, "42"));
    assert(hasSpan(spans, SyntaxHighlightKind::Annotation, source, "@Anno"));
    assert(hasSpan(spans, SyntaxHighlightKind::Comment, source, "// return"));
}

void testGutterHitTest() {
    const auto firstLine = hitTestGutter(275.0, 8.0, 0.0, 280.0, 20);
    assert(firstLine && firstLine->line == 0 &&
           firstLine->zone == GutterHitZone::LineNumber);
    const auto annotation = hitTestGutter(40.0, 28.0, 0.0, 280.0, 20);
    assert(annotation && annotation->line == 1 &&
           annotation->zone == GutterHitZone::Annotation);
    const auto scrolled = hitTestGutter(49.0, 8.0, 60.0, 50.0, 20);
    assert(scrolled && scrolled->line == 3 &&
           scrolled->zone == GutterHitZone::LineNumber);
    assert(!hitTestGutter(10.0, 7.0, 0.0, 50.0, 20));
    assert(!hitTestGutter(10.0, 408.0, 0.0, 50.0, 20));
    assert(!hitTestGutter(50.0, 8.0, 0.0, 50.0, 20));
    assert(!hitTestGutter(NAN, 8.0, 0.0, 50.0, 20));
}

} // namespace

int main() {
    testDiffPairing();
    testTextDiff();
    testDiffCollapseAndSplitLayout();
    testInlineDiff();
    testVisibilityRules();
    testFuzzyMatch();
    testTerminalBuffer();
    testGitGraph();
    testGitReferenceTree();
    testGutterHitTest();
    testSmallUtilities();
    return 0;
}
