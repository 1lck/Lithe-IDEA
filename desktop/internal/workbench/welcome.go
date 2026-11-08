package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/flex"
	"github.com/vivaui/viva/ui"
)

// The identities of the start screen's controls.
var (
	welcomeSearch      = tree.ID(welcomePage, "search")
	welcomeOpen        = tree.ID(welcomePage, "open")
	welcomeNavProjects = tree.ID(welcomePage, "nav-projects")
	welcomeNavSettings = tree.ID(welcomePage, "nav-settings")
	welcomeList        = tree.ID(welcomePage, "list")
	// welcomeRows identifies the recent project rows: welcomeRows.At(i) is a.recent[i],
	// whether or not the filter currently shows it.
	welcomeRows = tree.Sub(welcomePage, tree.Name("rows"))
)

const (
	welcomeSidebarWidth = 240
	welcomeRowHeight    = 48
	// welcomeAvatarSize is the side of the badge that starts a recent project's row; the
	// row is 16 pixels taller, so the badge has 8 above and below it.
	welcomeAvatarSize = 32
)

// welcomeState is what the start screen remembers between frames.
type welcomeState struct {
	// search filters the project list. App.Config hands it to the platform text
	// service, so it lives as long as the window.
	search flex.Field

	// query is the search text folded for matching and queryText the text it was folded
	// from, so the fold runs when the text changes and not on every frame.
	queryText string
	query     string

	// version is the sidebar's version line in the language versionFor, kept so a frame
	// does not format it again.
	version    string
	versionFor *i18n.Messages

	// rows holds what a recent project shows, by path. The list repaints on every hover,
	// and splitting names, shortening paths and folding case for each row each time would
	// allocate for nothing, so it is derived once per path.
	rows map[string]welcomeRow
	// home is the user's home folder, read once; paths under it show as "~/...".
	home     string
	homeRead bool
}

// welcomeRow is the derived text of one recent project.
type welcomeRow struct {
	// name is the folder's name and path its location, shortened with "~" when it is
	// under the home folder.
	name, path string
	// needle is the full path folded for matching the search text.
	needle string
	// identity is the project's badge, derived with the text because it hashes the path.
	identity projectIdentity
}

// row returns what the project at path shows. listed is the length of the recent list;
// the cache is dropped when it outgrows the list by a margin, so projects that left
// the list do not stay in memory.
func (w *welcomeState) row(path string, listed int) welcomeRow {
	if r, ok := w.rows[path]; ok {
		return r
	}
	if !w.homeRead {
		w.home, _ = os.UserHomeDir()
		w.homeRead = true
	}
	name := filepath.Base(path)
	r := welcomeRow{
		name:     name,
		path:     welcomeShorten(path, w.home),
		needle:   strings.ToLower(path),
		identity: identityOf(path, name),
	}
	if w.rows == nil {
		w.rows = make(map[string]welcomeRow, 32)
	} else if len(w.rows) >= 2*listed+16 {
		clear(w.rows)
	}
	w.rows[path] = r
	return r
}

// needle is the search text folded for matching; empty shows every project.
func (w *welcomeState) needle() string {
	text := w.search.Text()
	if text != w.queryText {
		w.queryText = text
		w.query = strings.ToLower(strings.TrimSpace(text))
	}
	return w.query
}

// welcomeShorten writes a path under home as "~" plus the rest. The separator is
// checked so /Users/ann does not shorten /Users/anna.
func welcomeShorten(path, home string) string {
	if home == "" || !strings.HasPrefix(path, home) {
		return path
	}
	rest := path[len(home):]
	if rest != "" && rest[0] != os.PathSeparator {
		return path
	}
	return "~" + rest
}

// welcomeInitial is the first letter of the application's name, the brand mark on the
// sidebar. It slices the name instead of building a string, so a frame allocates nothing.
func welcomeInitial(name string) string {
	_, size := utf8.DecodeRuneInString(name)
	return name[:size]
}

// drawWelcome is the screen shown while no project is open: a sidebar with the
// application's name and the places it leads to, and the list of recent projects.
func (a *App) drawWelcome(f *flex.Frame) {
	f.Row().Fill().Background(a.colors.Editor).Children(func() {
		a.drawWelcomeSidebar(f)
		f.Divider()
		a.drawWelcomeContent(f)
	})
}

func (a *App) drawWelcomeSidebar(f *flex.Frame) {
	w := &a.welcome
	if w.versionFor != a.text {
		w.version, w.versionFor = a.text.App.Version(a.version), a.text
	}
	f.Column().Width(welcomeSidebarWidth).Shrink(0).Background(a.colors.Panel).Children(func() {
		// The system's window buttons sit in this strip, so it stays empty; it only has
		// to move the window like a title bar does.
		f.Row().FillWidth().Height(titleBarHeight).MovesWindow()
		f.Row().Items(flex.Center).Gap(12).PadX(16).PadY(8).Children(func() {
			// The mark takes the primary color and its foreground as a pair, so the letter is
			// readable in both themes without the screen choosing colors of its own.
			f.Row().Size(32, 32).Shrink(0).Center().Radius(a.theme.Metrics.RadiusItem()).Background(a.theme.Primary).Children(func() {
				f.Text(welcomeInitial(a.text.App.Name)).Bold().Color(a.theme.PrimaryForeground)
			})
			f.Column().Children(func() {
				f.Text(a.text.App.Name).Bold()
				f.Text(w.version).Muted().FontSize(a.theme.Metrics.FontSizeS)
			})
		})
		f.Column().Gap(4).Pad(8).Children(func() {
			// Projects is the screen being shown, so its button is only a marker of the
			// place; Settings opens the dialog.
			f.Button(welcomeNavProjects, a.text.Welcome.Projects).Secondary().FillWidth()
			if f.Button(welcomeNavSettings, a.text.Welcome.Settings).Ghost().FillWidth().Clicked() {
				a.openSettings(surfaceButton)
			}
		})
	})
}

func (a *App) drawWelcomeContent(f *flex.Frame) {
	f.Column().Grow(1).Children(func() {
		f.Row().FillWidth().Height(titleBarHeight).MovesWindow()
		f.Row().Items(flex.Center).Gap(8).PadX(24).PadY(8).Children(func() {
			f.Field(&a.welcome.search, welcomeSearch, a.text.Welcome.SearchLabel, a.text.Welcome.SearchPlaceholder).Grow(1)
			if f.Button(welcomeOpen, a.text.Welcome.Open).Clicked() {
				a.chooseProject(surfaceButton)
			}
		})
		a.drawWelcomeProjects(f)
	})
}

// drawWelcomeProjects is the recent project list, or what stands in for it.
func (a *App) drawWelcomeProjects(f *flex.Frame) {
	if len(a.recent) == 0 {
		f.Column().Grow(1).Center().Gap(4).Children(func() {
			f.Text(a.text.Welcome.EmptyTitle).Bold()
			f.Text(a.text.Welcome.EmptyHint).Muted()
		})
		return
	}
	query := a.welcome.needle()
	shown := 0
	// open is acted on after the list is declared: opening a project replaces the recent
	// list, which this loop is still reading.
	open := ""
	f.ScrollArea(welcomeList).Grow(1).PadX(16).PadY(4).Gap(4).Children(func() {
		for i := range a.recent {
			entry := &a.recent[i]
			row := a.welcome.row(entry.Path, len(a.recent))
			if query != "" && !strings.Contains(row.needle, query) {
				continue
			}
			shown++
			// A project whose folder is gone stays clickable, so opening it can say why
			// it did not open; the mark only warns beforehand.
			missing := ""
			if a.missing[entry.Path] {
				missing = a.text.Welcome.Missing
			}
			item := f.Row().Height(welcomeRowHeight).Items(flex.Center).Gap(12).PadX(12).
				Radius(a.theme.Metrics.RadiusItem()).
				HitWith(welcomeRows.At(i), row.name, ui.HitOptions{
					Role:        ui.RoleButton,
					Cursor:      ui.PointerCursorHand,
					Description: row.path,
					Hint:        missing,
				}).
				Hover(flex.Look{}.Background(a.colors.Hover)).
				Pressed(flex.Look{}.Background(a.colors.Active))
			item.Children(func() {
				avatar := drawProjectAvatar(f, row.identity, welcomeAvatarSize)
				if missing != "" {
					// The warning beside the name says why; the faded badge says it at a glance.
					avatar.Opacity(identityMissingOpacity)
				}
				f.Column().Grow(1).Children(func() {
					f.Text(row.name).Ellipsis()
					f.Text(row.path).Ellipsis().Muted().FontSize(a.theme.Metrics.FontSizeS)
				})
				if missing != "" {
					f.Text(missing).Shrink(0).Color(a.colors.Warning).FontSize(a.theme.Metrics.FontSizeS)
				}
			})
			if item.Clicked() {
				open = entry.Path
			}
		}
		if shown == 0 {
			f.Text(a.text.Welcome.NoMatches).Muted().TextCenter().PadY(24)
		}
	})
	if open != "" {
		a.performed("workspace.recent.open", surfaceButton)
		a.openProject(open)
	}
}
