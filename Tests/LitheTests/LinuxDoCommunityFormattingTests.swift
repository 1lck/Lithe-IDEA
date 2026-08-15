import Testing
@testable import Lithe

struct LinuxDoCommunityFormattingTests {
    @Test
    func formatsForumMetadataForCompactRows() {
        #expect(LinuxDoCommunityFormatting.compactNumber(999) == "999")
        #expect(LinuxDoCommunityFormatting.compactNumber(1_250) == "1.2K")
        #expect(LinuxDoCommunityFormatting.compactNumber(12_500) == "12K")
        #expect(LinuxDoCommunityFormatting.compactNumber(2_400_000) == "2.4M")
    }

    @Test
    func derivesReadableAvatarInitials() {
        #expect(LinuxDoCommunityFormatting.initials("Ada Lovelace") == "AL")
        #expect(LinuxDoCommunityFormatting.initials("linuxdo") == "L")
    }

    @Test
    func projectsSanitizedHTMLIntoReadableNativeText() {
        let value = LinuxDoCommunityFormatting.plainText("<p>Hello <strong>community</strong></p>")
        #expect(value == "Hello community")
    }
}
