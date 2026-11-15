package workbench

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// The update dialog shows what a version changed before the user decides to download it. As
// in Motty, the signed feed carries the version, the archives and the patches, and the notes
// are read on their own once a check found a version: they are only shown, and what gets
// installed is decided by the digests of the signed feed, so the notes are not signed. They
// live beside the feed, stable.notes.md next to stable.json, which the release workflows
// publish together, so a mirror of the feed's directory has them too. Their first line names
// the version they describe, <!-- lithe-update-notes version=0.8.0 -->, and notes for another
// version, as when the feed and the notes are uploaded one after the other, are not shown. At
// most updateNotesLimit bytes are read, cut at a character boundary, as Motty reads. Notes that
// cannot be read leave the dialog without them, which says there are none; the rest of it, the
// version, sizes and buttons, does not wait for them.

const (
	// updateNotesLimit is the most of the notes read.
	updateNotesLimit = 16 << 10
	// updateNotesTimeout bounds one read of the notes.
	updateNotesTimeout = 30 * time.Second
	// updateNotesHeader starts the first line of the notes, which names their version.
	updateNotesHeader = "<!-- lithe-update-notes version="
)

// fetchUpdateNotes reads at most limit bytes of the notes at address; a test replaces it.
var fetchUpdateNotes = func(ctx context.Context, address string, limit int64) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("update notes: %s answered %s", address, response.Status)
	}
	return io.ReadAll(io.LimitReader(response.Body, limit+1))
}

// updateNotesURL is the address of the notes beside the feed at feedURL: its file name with
// .notes.md for .json.
func updateNotesURL(feedURL string) (string, error) {
	parsed, err := url.Parse(feedURL)
	if err != nil {
		return "", err
	}
	parsed.Path = strings.TrimSuffix(parsed.Path, ".json") + ".notes.md"
	parsed.RawPath = ""
	return parsed.String(), nil
}

// updateNotesBody is the Markdown of notes for version: what follows their first line when it
// names version. A body longer than updateNotesLimit is cut at a character boundary.
func updateNotesBody(data []byte, version string) (string, error) {
	data = bytes.TrimPrefix(data, []byte("\ufeff"))
	first, rest, _ := bytes.Cut(data, []byte("\n"))
	line := strings.TrimSpace(string(first))
	named, found := strings.CutPrefix(line, updateNotesHeader)
	named, closed := strings.CutSuffix(named, "-->")
	if !found || !closed {
		return "", fmt.Errorf("update notes: the first line does not name their version")
	}
	if named = strings.TrimSpace(named); named != version {
		return "", fmt.Errorf("update notes: they describe %s, not %s", named, version)
	}
	cut := false
	if len(rest) > updateNotesLimit {
		rest, cut = rest[:updateNotesLimit], true
	}
	// A character the limit cut in half is dropped: at most three bytes of it are left.
	for i := 0; cut && i < utf8.UTFMax-1 && len(rest) > 0; i++ {
		if r, size := utf8.DecodeLastRune(rest); r != utf8.RuneError || size != 1 {
			break
		}
		rest = rest[:len(rest)-1]
	}
	body := strings.TrimSpace(string(rest))
	if cut {
		body += "\n\n…"
	}
	return body, nil
}

// loadUpdateNotes fetches the notes of version from beside target's feed, unless they are the
// notes already shown or on the way. No version clears them.
func (a *App) loadUpdateNotes(target updateTarget, version string) {
	u := a.updates
	key := ""
	if version != "" {
		key = target.feedURL + "\n" + version
	}
	u.mu.Lock()
	same := u.notesFor == key
	u.notesFor = key
	u.mu.Unlock()
	if same {
		return
	}
	a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Notes, s.NotesLoading = "", key != "" })
	if key == "" {
		return
	}
	address, err := updateNotesURL(target.feedURL)
	if err != nil {
		a.updateNotesRead(key, "", err)
		return
	}
	parent := a.operationContext(context.Background())
	// The fetch is read here, on the window thread, as the check reads u.open: a test that
	// replaced it puts it back once the window closes, which the fetch may outlast.
	fetch := fetchUpdateNotes
	go func() {
		ctx, cancel := context.WithTimeout(parent, updateNotesTimeout)
		defer cancel()
		data, err := fetch(ctx, address, updateNotesLimit+int64(len(updateNotesHeader))+256)
		body := ""
		if err == nil {
			body, err = updateNotesBody(data, version)
		}
		a.post(func(a *App) { a.updateNotesRead(key, body, err) })
	}()
}

// updateNotesRead takes in the notes fetched for key, unless a check has moved on to another
// version since. Notes that could not be read are logged and the dialog shows none.
func (a *App) updateNotesRead(key, body string, err error) {
	u := a.updates
	u.mu.Lock()
	current := u.notesFor == key
	u.mu.Unlock()
	if !current {
		return
	}
	if err != nil {
		a.backgroundFailed("update_notes", err)
	}
	a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Notes, s.NotesLoading = body, false })
}
