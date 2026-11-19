package searchprefs

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestSearchPreferencesReadOnlyOpenGuardedSaveAndReadBack(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	source := Source{Root: filepath.Join(t.TempDir(), "preferences")}
	initial, err := source.Load(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(source.Root); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("read-only opening created preferences", err)
	}
	search, replace := uint64(32<<20), uint64(24<<20)
	saved, err := source.Save(ctx, initial, core.StoredSearchPreferences{MaxFileBytes: &search, ReplacementMaxFileBytes: &replace})
	if err != nil {
		t.Fatal(err)
	}
	if saved.Effective.MaxFileBytes != search || saved.Effective.ReplacementMaxFileBytes != replace {
		t.Fatalf("read-back %+v", saved.Effective)
	}
	reopened, err := source.Load(ctx)
	if err != nil || reopened.Effective != saved.Effective {
		t.Fatalf("reopen %+v %v", reopened, err)
	}
	if err = os.WriteFile(saved.Path, []byte(`{"maxFileBytes":1048576,"future":true}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = source.Save(ctx, saved, core.StoredSearchPreferences{}); !errors.Is(err, configfile.ErrConflict) {
		t.Fatalf("external edit not protected: %v", err)
	}
	latest, err := source.Load(ctx)
	if err != nil {
		t.Fatal(err)
	}
	reset, err := source.Save(ctx, latest, core.StoredSearchPreferences{})
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(reset.Path)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "{\n  \"future\": true\n}\n" {
		t.Fatalf("reset lost unrelated value: %s", data)
	}
}
