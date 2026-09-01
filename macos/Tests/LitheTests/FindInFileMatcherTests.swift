import Foundation
import Testing
@testable import Lithe

struct FindInFileMatcherTests {
    private let defaultOptions = FindInFileOptions()

    @Test
    func literalSearchIsCaseAndDiacriticInsensitiveByDefault() {
        // 回归保护：默认行为与既有查找一致（大小写、音调都不敏感）
        let source = "Café cafe CAFE" as NSString
        let matcher = FindInFileMatcher(query: "cafe", options: defaultOptions)

        #expect(matcher.isValid)
        #expect(matcher.matchRanges(in: source) == [NSRange(location: 0, length: 4), NSRange(location: 5, length: 4), NSRange(location: 10, length: 4)])
    }

    @Test
    func matchCaseRequiresExactCase() {
        let source = "Café cafe CAFE" as NSString
        let matcher = FindInFileMatcher(
            query: "cafe",
            options: FindInFileOptions(matchCase: true)
        )

        #expect(matcher.matchRanges(in: source) == [NSRange(location: 5, length: 4)])
    }

    @Test
    func wholeWordsRejectsCandidatesAndKeepsScanning() {
        // 下划线与数字算词字符、串首串尾视为边界；被拒候选之后继续向后扫描
        let source = "cat catalog _cat cat1 cat" as NSString
        let matcher = FindInFileMatcher(
            query: "cat",
            options: FindInFileOptions(wholeWords: true)
        )

        #expect(matcher.matchRanges(in: source) == [NSRange(location: 0, length: 3), NSRange(location: 22, length: 3)])
    }

    @Test
    func wholeWordsTreatsUnicodeLettersAsWordCharacters() {
        let source = "écat cat" as NSString
        let matcher = FindInFileMatcher(
            query: "cat",
            options: FindInFileOptions(wholeWords: true)
        )

        #expect(matcher.matchRanges(in: source) == [NSRange(location: 5, length: 3)])
    }

    @Test
    func regularExpressionEnumeratesMatches() {
        let source = "alice@example.com bob@test.org" as NSString
        let matcher = FindInFileMatcher(
            query: "(\\w+)@(\\w+)",
            options: FindInFileOptions(regularExpression: true)
        )

        #expect(matcher.isValid)
        #expect(matcher.matchRanges(in: source) == [NSRange(location: 0, length: 13), NSRange(location: 18, length: 8)])
    }

    @Test
    func regularExpressionReplacementExpandsCaptureGroups() {
        let source = "alice@example.com bob@test.org" as NSString
        let matcher = FindInFileMatcher(
            query: "(\\w+)@(\\w+)",
            options: FindInFileOptions(regularExpression: true)
        )

        // NSRegularExpression 的模板只展开 $n 数字引用；${name} 原样返回
        #expect(
            matcher.replacement(for: source, matchRange: NSRange(location: 0, length: 13), template: "$2.$1")
                == "example.alice"
        )
        #expect(
            matcher.replacement(for: source, matchRange: NSRange(location: 18, length: 8), template: "$2.$1")
                == "test.bob"
        )
    }

    @Test
    func literalReplacementUsesTemplateVerbatim() {
        let source = "foo bar" as NSString
        let matcher = FindInFileMatcher(query: "foo", options: defaultOptions)

        #expect(
            matcher.replacement(for: source, matchRange: NSRange(location: 0, length: 3), template: "$1 baz")
                == "$1 baz"
        )
    }

    @Test
    func invalidRegularExpressionReportsInvalidAndNoMatches() {
        let source = "hello world" as NSString
        let matcher = FindInFileMatcher(
            query: "a(",
            options: FindInFileOptions(regularExpression: true)
        )

        #expect(!matcher.isValid)
        #expect(matcher.matchRanges(in: source).isEmpty)
        #expect(
            matcher.replacement(for: source, matchRange: NSRange(location: 0, length: 5), template: "$1")
                == "$1"
        )
    }

    @Test
    func emptyQueryYieldsNoMatches() {
        let source = "hello world" as NSString

        #expect(FindInFileMatcher(query: "", options: defaultOptions).matchRanges(in: source).isEmpty)
        #expect(
            FindInFileMatcher(query: "", options: FindInFileOptions(regularExpression: true))
                .matchRanges(in: source).isEmpty
        )
    }

    @Test
    func zeroWidthRegexMatchesAreSkipped() {
        let source = "bab" as NSString
        let matcher = FindInFileMatcher(
            query: "a*",
            options: FindInFileOptions(regularExpression: true)
        )

        #expect(matcher.isValid)
        #expect(matcher.matchRanges(in: source) == [NSRange(location: 1, length: 1)])
    }

    @Test
    func regexWithWholeWordsWrapsPatternInWordBoundaries() {
        let source = "cat catalog concat" as NSString
        let matcher = FindInFileMatcher(
            query: "cat",
            options: FindInFileOptions(wholeWords: true, regularExpression: true)
        )

        #expect(matcher.isValid)
        #expect(matcher.matchRanges(in: source) == [NSRange(location: 0, length: 3)])
    }

    @Test
    func subRangeEnumerationSeesContextOutsideTheRange() {
        // 窗口外相邻字符必须参与判定：范围首部的 cat 前一个字符在范围之外
        let source = "zcat cat" as NSString
        let matcher = FindInFileMatcher(
            query: "cat",
            options: FindInFileOptions(wholeWords: true)
        )

        #expect(matcher.matchRanges(in: source, range: NSRange(location: 1, length: 3)).isEmpty)
        #expect(matcher.matchRanges(in: source, range: NSRange(location: 5, length: 3)) == [NSRange(location: 5, length: 3)])
    }

    @Test
    func literalScanProducesNonOverlappingMatches() {
        let source = "aaaa" as NSString
        let matcher = FindInFileMatcher(query: "aa", options: defaultOptions)

        #expect(matcher.matchRanges(in: source) == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
    }
}
