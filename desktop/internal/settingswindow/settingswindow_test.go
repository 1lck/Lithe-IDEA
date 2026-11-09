package settingswindow

import (
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// The tests here cover the logic that needs no screen: which pages a search lists, what the
// breadcrumb says, how the values map onto the controls, and what Enter and Escape mean.
// Opening, raising and closing a native window need a running application and are left to
// the manual check of the window.

// english and chinese are the two catalogs' settings words.
func english() *i18n.SettingsMessages { return &i18n.For(i18n.English).Settings }
func chinese() *i18n.SettingsMessages { return &i18n.For(i18n.Chinese).Settings }

// pagesOf lists the pages of rows in order, so a test states the shape of the sidebar in one
// line.
func pagesOf(rows []row) []pageID {
	pages := make([]pageID, len(rows))
	for i, r := range rows {
		pages[i] = r.page
	}
	return pages
}

func TestParentsTableKeepsGroupsBesideTheirPages(t *testing.T) {
	for id := pageID(0); id < pageCount; id++ {
		parent := parents[id]
		if parent == noPage {
			continue
		}
		if parent >= id {
			t.Fatalf("page %d is listed before its group %d", id, parent)
		}
		if parents[parent] != noPage {
			t.Fatalf("page %d is in group %d, which is itself inside a group", id, parent)
		}
		// appendVisible walks a group's pages from the entry after it, so every entry
		// between a group and one of its pages must be a page of the same group.
		for between := parent + 1; between < id; between++ {
			if parents[between] != parent {
				t.Fatalf("page %d sits between group %d and its page %d", between, parent, id)
			}
		}
	}
}

func TestOnlyAppearanceIsAGroup(t *testing.T) {
	for id := pageID(0); id < pageCount; id++ {
		if got, want := isGroup(id), id == pageAppearance; got != want {
			t.Errorf("isGroup(%d) = %v, want %v", id, got, want)
		}
	}
}

func TestInitialPageIsOnScreen(t *testing.T) {
	if isGroup(initialPage) {
		t.Fatal("a window opens on a group, which has no page to show")
	}
	open := initialOpen()
	if parent := parents[initialPage]; parent != noPage && !open[parent] {
		t.Fatalf("the initial page is in group %d, which starts collapsed", parent)
	}
	if !slices.Contains(pagesOf(appendVisible(nil, english(), &open, "")), initialPage) {
		t.Fatal("the initial page is not listed by the sidebar")
	}
}

func TestEveryEntryHasATitleInBothLanguages(t *testing.T) {
	for _, messages := range []*i18n.SettingsMessages{english(), chinese()} {
		seen := map[string]pageID{}
		for id := pageID(0); id < pageCount; id++ {
			title := titleOf(messages, id)
			if title == "" {
				t.Fatalf("page %d has no title", id)
			}
			if other, dup := seen[title]; dup {
				t.Fatalf("pages %d and %d are both called %q", other, id, title)
			}
			seen[title] = id
		}
		if got := titleOf(messages, noPage); got != "" {
			t.Fatalf("titleOf(noPage) = %q, want empty", got)
		}
	}
}

func TestDefaultSidebarListsTheTopLevelWithAppearanceExpanded(t *testing.T) {
	open := initialOpen()
	rows := appendVisible(nil, english(), &open, "")
	want := []row{
		{page: pageAppearance, group: true, expanded: true},
		{page: pageGeneral, level: 1},
		{page: pageUpdates, level: 1},
		{page: pageNetwork, level: 1},
		{page: pageEditor, level: 1},
		{page: pageKeymap, level: 1},
		{page: pageProcessTermination, level: 1},
		{page: pagePlugins},
		{page: pageVersionControl},
		{page: pageBuild},
		{page: pageLanguages},
		{page: pageTools},
		{page: pageAI},
	}
	if !slices.Equal(rows, want) {
		t.Fatalf("rows = %v, want %v", rows, want)
	}
}

func TestCollapsedGroupHidesItsPages(t *testing.T) {
	var open [pageCount]bool
	rows := appendVisible(nil, english(), &open, "")
	if len(rows) != 7 {
		t.Fatalf("rows = %v, want the group and the six pages on the top level", rows)
	}
	if first := rows[0]; first.page != pageAppearance || !first.group || first.expanded {
		t.Fatalf("first row = %+v, want the collapsed group", first)
	}
	for _, r := range rows[1:] {
		if r.level != 0 || r.group {
			t.Fatalf("row %+v should be a page on the top level", r)
		}
	}
}

func TestSearchKeepsTheGroupOfAMatchingPageExpanded(t *testing.T) {
	// A search expands the groups it lists whatever the user left them as, so the match
	// is not hidden inside a collapsed one.
	var collapsed [pageCount]bool
	open := initialOpen()
	for name, state := range map[string]*[pageCount]bool{"collapsed": &collapsed, "expanded": &open} {
		rows := appendVisible(nil, english(), state, foldQuery("Network"))
		want := []row{{page: pageAppearance, group: true, expanded: true}, {page: pageNetwork, level: 1}}
		if !slices.Equal(rows, want) {
			t.Errorf("%s: rows = %v, want %v", name, rows, want)
		}
	}
}

func TestSearchOnAGroupTitleKeepsAllItsPages(t *testing.T) {
	var open [pageCount]bool
	rows := appendVisible(nil, english(), &open, foldQuery("appearance"))
	want := []pageID{pageAppearance, pageGeneral, pageUpdates, pageNetwork, pageEditor, pageKeymap, pageProcessTermination}
	if got := pagesOf(rows); !slices.Equal(got, want) {
		t.Fatalf("pages = %v, want %v", got, want)
	}
}

func TestSearchOnATopLevelPageListsOnlyIt(t *testing.T) {
	open := initialOpen()
	// The query is folded, so "  AI " finds "AI" and the group, which has no match, is dropped.
	rows := appendVisible(nil, english(), &open, foldQuery("  AI "))
	if want := []row{{page: pageAI}}; !slices.Equal(rows, want) {
		t.Fatalf("rows = %v, want %v", rows, want)
	}
}

func TestSearchIgnoresCase(t *testing.T) {
	open := initialOpen()
	lower := appendVisible(nil, english(), &open, foldQuery("version control"))
	upper := appendVisible(nil, english(), &open, foldQuery("VERSION CONTROL"))
	if !slices.Equal(lower, upper) || len(lower) != 1 || lower[0].page != pageVersionControl {
		t.Fatalf("lower = %v, upper = %v, want only the version control page", lower, upper)
	}
}

func TestSearchWorksInChinese(t *testing.T) {
	open := initialOpen()
	rows := appendVisible(nil, chinese(), &open, foldQuery(" 通用 "))
	want := []row{{page: pageAppearance, group: true, expanded: true}, {page: pageGeneral, level: 1}}
	if !slices.Equal(rows, want) {
		t.Fatalf("rows = %v, want %v", rows, want)
	}
}

func TestSearchWithNoMatchListsNothing(t *testing.T) {
	open := initialOpen()
	if rows := appendVisible(nil, english(), &open, foldQuery("no such page")); len(rows) != 0 {
		t.Fatalf("rows = %v, want none", rows)
	}
}

func TestBlankQueryListsEverything(t *testing.T) {
	open := initialOpen()
	plain := appendVisible(nil, english(), &open, "")
	blank := appendVisible(nil, english(), &open, foldQuery("   "))
	if !slices.Equal(plain, blank) {
		t.Fatalf("a blank query listed %v, want %v", blank, plain)
	}
}

func TestAppendVisibleKeepsWhatIsAlreadyInDst(t *testing.T) {
	open := initialOpen()
	dst := []row{{page: pageAI}}
	rows := appendVisible(dst, english(), &open, "")
	if len(rows) != 14 || rows[0] != (row{page: pageAI}) {
		t.Fatalf("rows = %v, want the old row followed by the 13 of the sidebar", rows)
	}
}

func TestAppendVisibleReusedBufferHoldsNoStaleRows(t *testing.T) {
	open := initialOpen()
	rows := appendVisible(nil, english(), &open, "")
	rows = appendVisible(rows[:0], english(), &open, foldQuery("network"))
	if len(rows) != 2 {
		t.Fatalf("rows = %v, want the group and the page", rows)
	}
}

func TestBreadcrumb(t *testing.T) {
	cases := []struct {
		page pageID
		want []string
	}{
		{pageGeneral, []string{"Appearance & Behavior", "General"}},
		{pageProcessTermination, []string{"Appearance & Behavior", "Process Termination Policy"}},
		{pageAppearance, []string{"Appearance & Behavior"}},
		{pagePlugins, []string{"Plugins"}},
		{pageAI, []string{"AI"}},
	}
	for _, tc := range cases {
		if got := appendBreadcrumb(nil, english(), tc.page); !slices.Equal(got, tc.want) {
			t.Errorf("breadcrumb of %d = %q, want %q", tc.page, got, tc.want)
		}
	}
	// It appends, so a buffer can be reused.
	got := appendBreadcrumb([]string{"x"}, english(), pageTools)
	if !slices.Equal(got, []string{"x", "Tools"}) {
		t.Errorf("breadcrumb appended to a buffer = %q", got)
	}
}

func TestToggleGroup(t *testing.T) {
	open := initialOpen()
	toggleGroup(&open, pageAppearance, false)
	if open[pageAppearance] {
		t.Fatal("toggling an expanded group did not collapse it")
	}
	toggleGroup(&open, pageAppearance, false)
	if !open[pageAppearance] {
		t.Fatal("toggling a collapsed group did not expand it")
	}
}

func TestToggleGroupDoesNothingWhileSearchingOrOffAGroup(t *testing.T) {
	open := initialOpen()
	before := open
	toggleGroup(&open, pageAppearance, true)
	toggleGroup(&open, pageGeneral, false)
	toggleGroup(&open, pagePlugins, false)
	toggleGroup(&open, noPage, false)
	if open != before {
		t.Fatalf("open = %v, want it unchanged %v", open, before)
	}
}

func TestThemeIndexAndValueAreInverse(t *testing.T) {
	for index, value := range themeValues {
		if got := themeIndex(value); got != index {
			t.Errorf("themeIndex(%q) = %d, want %d", value, got, index)
		}
		if got := themeValue(index); got != value {
			t.Errorf("themeValue(%d) = %q, want %q", index, got, value)
		}
	}
	if got := themeIndex("sepia"); got != 0 {
		t.Errorf("an unknown theme chose segment %d, want the one that follows the system", got)
	}
	for _, index := range []int{-1, len(themeValues)} {
		if got := themeValue(index); got != "" {
			t.Errorf("themeValue(%d) = %q, want empty", index, got)
		}
	}
}

func TestLanguageIndexAndCodeAreInverse(t *testing.T) {
	if languageIndex("") != 0 || languageIndex("fr") != 0 {
		t.Error("an empty or unknown code must choose the option that follows the system")
	}
	for position, language := range i18n.Languages {
		code := language.Code()
		if got := languageIndex(code); got != position+1 {
			t.Errorf("languageIndex(%q) = %d, want %d", code, got, position+1)
		}
		if got := languageCode(position + 1); got != code {
			t.Errorf("languageCode(%d) = %q, want %q", position+1, got, code)
		}
	}
	for _, index := range []int{-1, 0, len(i18n.Languages) + 1} {
		if got := languageCode(index); got != "" {
			t.Errorf("languageCode(%d) = %q, want empty", index, got)
		}
	}
}

func TestLabelsLineUpWithTheirIndexes(t *testing.T) {
	themes := themeLabelsFor(english(), false)
	if want := []string{"Follow System (Light)", "Light", "Dark"}; !slices.Equal(themes, want) {
		t.Errorf("light system theme labels = %q, want %q", themes, want)
	}
	themes = themeLabelsFor(chinese(), true)
	if want := []string{"跟随系统（深色）", "浅色", "深色"}; !slices.Equal(themes, want) {
		t.Errorf("dark system theme labels = %q, want %q", themes, want)
	}
	if len(themes) != len(themeValues) {
		t.Errorf("%d theme labels for %d segments", len(themes), len(themeValues))
	}

	languages := languageLabelsFor(english(), i18n.Chinese)
	if len(languages) != len(i18n.Languages)+1 {
		t.Fatalf("%d language labels for %d options", len(languages), len(i18n.Languages)+1)
	}
	if want := "Follow System (简体中文)"; languages[0] != want {
		t.Errorf("first language label = %q, want %q", languages[0], want)
	}
	for _, language := range i18n.Languages {
		// Each language is named in its own name, at the option that stores its code.
		if got := languages[languageIndex(language.Code())]; got != language.Native() {
			t.Errorf("label of %q = %q, want %q", language.Code(), got, language.Native())
		}
	}
}

func TestWindowDarkFollowsThePickedLookElseTheSystem(t *testing.T) {
	cases := []struct {
		theme  string
		system bool
		want   bool
	}{
		{themeLight, true, false},
		{themeLight, false, false},
		{themeDark, true, true},
		{themeDark, false, true},
		{"", true, true},
		{"", false, false},
		{"sepia", true, true},
		{"sepia", false, false},
	}
	for _, tc := range cases {
		if got := windowDark(tc.theme, tc.system); got != tc.want {
			t.Errorf("windowDark(%q, %v) = %v, want %v", tc.theme, tc.system, got, tc.want)
		}
	}
}

func TestSanitizeKeepsWhatTheControlsCanShow(t *testing.T) {
	kept := Values{Language: i18n.Chinese.Code(), Theme: themeDark}
	if got := sanitize(kept); got != kept {
		t.Errorf("sanitize(%+v) = %+v, want it unchanged", kept, got)
	}
	if got := sanitize(Values{Language: "fr", Theme: "sepia"}); got != (Values{}) {
		t.Errorf("sanitize of unknown values = %+v, want the defaults", got)
	}
	if got := sanitize(Values{Language: "en", Theme: "sepia"}); got != (Values{Language: "en"}) {
		t.Errorf("sanitize dropped the known language: %+v", got)
	}
}

func TestNewSessionStartsFromTheSettingsInForce(t *testing.T) {
	s := newSession(Values{Language: "zh-Hans", Theme: themeDark})
	if s.values != (Values{Language: "zh-Hans", Theme: themeDark}) {
		t.Errorf("values = %+v, want the settings in force", s.values)
	}
	if s.page != initialPage || s.open != initialOpen() {
		t.Errorf("page = %d, open = %v, want the initial ones", s.page, s.open)
	}
	if s.finished.Load() {
		t.Error("a new session is already finished")
	}
	if got := newSession(Values{Language: "fr", Theme: "sepia"}).values; got != (Values{}) {
		t.Errorf("displayed unknown settings = %+v, want the defaults", got)
	}
}

func TestAcceptClosesOnce(t *testing.T) {
	s := newSession(Values{})
	if !s.accept() {
		t.Fatal("the first OK did nothing")
	}
	if s.accept() {
		t.Fatal("a second OK acted")
	}
	if !s.finished.Load() {
		t.Fatal("the session is not finished after OK")
	}
	if s.cancel() {
		t.Fatal("Cancel acted after OK")
	}
}

func TestCancelAppliesNothing(t *testing.T) {
	s := newSession(Values{})
	s.values.Theme = themeDark
	if !s.cancel() {
		t.Fatal("the first Cancel did nothing")
	}
	if s.accept() {
		t.Fatal("OK applied after Cancel")
	}
	if s.cancel() {
		t.Fatal("a second Cancel acted")
	}
}

func TestClosedWindowIsNotAcceptedAgain(t *testing.T) {
	// The system's close button marks the session finished without choosing OK or Cancel;
	// a late Enter must not act on a window that is gone.
	s := newSession(Values{})
	s.finished.Store(true)
	if s.accept() {
		t.Fatal("OK applied after the window had closed")
	}
}

func TestDecideKey(t *testing.T) {
	cases := []struct {
		name string
		key  keyKind
		ctx  keyContext
		want keyAction
	}{
		{"enter is OK", keyEnter, keyContext{}, actionAccept},
		{"enter on a control that acts on it", keyEnter, keyContext{ownsEnter: true}, actionNone},
		{"enter in the search field", keyEnter, keyContext{searching: true, queryEmpty: true}, actionNone},
		{"enter in the search field with text", keyEnter, keyContext{searching: true}, actionNone},
		{"enter with a list open", keyEnter, keyContext{selectOpen: true}, actionNone},
		{"escape is Cancel", keyEscape, keyContext{}, actionCancel},
		{"escape on a control", keyEscape, keyContext{ownsEnter: true}, actionCancel},
		{"escape empties the search field first", keyEscape, keyContext{searching: true}, actionClearSearch},
		{"escape in an empty search field", keyEscape, keyContext{searching: true, queryEmpty: true}, actionCancel},
		{"escape with a list open", keyEscape, keyContext{selectOpen: true}, actionNone},
		{"escape with a list open over the search text", keyEscape, keyContext{selectOpen: true, searching: true}, actionNone},
		{"another key", keyOther, keyContext{}, actionNone},
		{"another key in the search field", keyOther, keyContext{searching: true}, actionNone},
	}
	for _, tc := range cases {
		if got := decideKey(tc.key, tc.ctx); got != tc.want {
			t.Errorf("%s: decideKey = %d, want %d", tc.name, got, tc.want)
		}
	}
}

func TestTilesColorTheTopLevelOnly(t *testing.T) {
	for id := pageID(0); id < pageCount; id++ {
		colored := tiles[id].color != (gfx.Color{})
		if want := parents[id] == noPage; colored != want {
			t.Errorf("page %d has a tile color: %v, want %v", id, colored, want)
		}
	}
}

func TestPalettes(t *testing.T) {
	light, dark := lightPalette(), darkPalette()
	if paletteFor(false) != light || paletteFor(true) != dark {
		t.Fatal("paletteFor does not return the palette of the look it is asked for")
	}
	if light.window == dark.window || light.sidebar == dark.sidebar || light.text == dark.text {
		t.Error("the light and the dark palettes share a surface or the text color")
	}
	if light.sidebar == light.window {
		t.Error("the sidebar must read as a different surface from the content")
	}
	for _, p := range []palette{light, dark} {
		if p.selectionColor(true) == p.selectionColor(false) {
			t.Error("a list with the focus and one without must select in different colors")
		}
	}
}

func TestWindowThemeTakesThePalette(t *testing.T) {
	for _, dark := range []bool{false, true} {
		p := paletteFor(dark)
		theme := windowTheme(dark, p)
		if theme.Background != p.window || theme.Foreground != p.text || theme.Primary != p.accent {
			t.Errorf("dark=%v: the theme did not take the palette's surface, text and accent", dark)
		}
	}
}

func TestFoldQuery(t *testing.T) {
	cases := map[string]string{
		"":          "",
		"   ":       "",
		" Network ": "network",
		"GENERAL":   "general",
		"通用":        "通用",
	}
	for in, want := range cases {
		if got := foldQuery(in); got != want {
			t.Errorf("foldQuery(%q) = %q, want %q", in, got, want)
		}
	}
}
