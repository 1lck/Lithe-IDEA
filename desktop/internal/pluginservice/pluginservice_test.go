package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// fakeKernel records what the stack asked Core to do.
type fakeKernel struct {
	review          core.MarketplaceReview
	reviewErr       error
	reviewManifest  json.RawMessage
	reviewExpected  [2]string
	reviewApproved  []json.RawMessage
	reviewCaps      map[string][]int
	plan            core.PluginBackendPlan
	planErr         error
	started         core.PluginBackendStarted
	startErr        error
	events          [][]core.BackendEvent
	stopErr         error
	destroyErr      error
	hostResponseErr error
	decoded         []string
	grammarErr      error
}

func (k *fakeKernel) ValidatePluginManifest(_ context.Context, manifest json.RawMessage, _ map[string][]int) (json.RawMessage, error) {
	return manifest, nil
}

func (k *fakeKernel) ReviewMarketplaceInstall(_ context.Context, manifest json.RawMessage, expectedID, expectedVersion string, approvedPrograms []json.RawMessage, capabilities map[string][]int) (core.MarketplaceReview, error) {
	k.reviewManifest = manifest
	k.reviewExpected = [2]string{expectedID, expectedVersion}
	k.reviewApproved = approvedPrograms
	k.reviewCaps = capabilities
	return k.review, k.reviewErr
}

func (k *fakeKernel) PlanPluginBackend(context.Context, json.RawMessage, core.PluginBackendDirectories) (core.PluginBackendPlan, error) {
	return k.plan, k.planErr
}

func (k *fakeKernel) StartPluginBackend(context.Context, core.PluginBackendStart) (core.PluginBackendStarted, error) {
	return k.started, k.startErr
}

func (k *fakeKernel) WaitBackendEvents(context.Context, string, int) ([]core.BackendEvent, error) {
	if len(k.events) == 0 {
		return nil, nil
	}
	batch := k.events[0]
	k.events = k.events[1:]
	return batch, nil
}

func (k *fakeKernel) StopPluginBackend(context.Context, string) error { return k.stopErr }

func (k *fakeKernel) DestroyPluginBackend(context.Context, string) error { return k.destroyErr }

func (k *fakeKernel) RespondPluginHostRequest(context.Context, string, string, json.RawMessage, *core.PluginHostFailure) error {
	return k.hostResponseErr
}

func (k *fakeKernel) DecodePluginGrammar(_ context.Context, _ json.RawMessage, languageID, source string) (core.PluginEditorLanguage, error) {
	k.decoded = append(k.decoded, languageID)
	if k.grammarErr != nil {
		return core.PluginEditorLanguage{}, k.grammarErr
	}
	return core.PluginEditorLanguage{
		ID:      languageID,
		Grammar: &core.PluginGrammar{Kind: "textmate", ScopeName: "source." + languageID, Source: source},
	}, nil
}

func TestOpenAssemblesEveryPart(t *testing.T) {
	service, err := Open(&fakeKernel{}, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if service.Manager == nil || service.Installer == nil || service.Backend == nil || service.HostServices == nil {
		t.Fatalf("service = %+v", service)
	}
	if service.Root == "" {
		t.Fatal("the service has no root")
	}
	if versions := service.Capabilities()["languages"]; len(versions) != 2 {
		t.Fatalf("capabilities = %v", service.Capabilities())
	}
}

func TestOpenRefusesIncompleteAssembly(t *testing.T) {
	cases := map[string]struct {
		kernel      Kernel
		preferences *store.Store
		root        string
	}{
		"no kernel":      {preferences: store.At(t.TempDir()), root: t.TempDir()},
		"no preferences": {kernel: &fakeKernel{}, root: t.TempDir()},
		"relative root":  {kernel: &fakeKernel{}, preferences: store.At(t.TempDir()), root: "plugins"},
		"empty root":     {kernel: &fakeKernel{}, preferences: store.At(t.TempDir())},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := Open(tc.kernel, tc.preferences, tc.root); !errors.Is(err, ErrAssembly) {
				t.Fatalf("err = %v", err)
			}
		})
	}
}

func TestReviewerAdaptsCoreReview(t *testing.T) {
	kernel := &fakeKernel{review: core.MarketplaceReview{
		ID:          "example",
		Version:     "1.0.0",
		Permissions: []string{"workspace.read"},
		Programs:    []json.RawMessage{json.RawMessage(`{"kind":"runtime"}`)},
		NewPrograms: []json.RawMessage{json.RawMessage(`{"kind":"run"}`)},
	}}
	approved := []json.RawMessage{json.RawMessage(`{"kind":"runtime"}`)}
	review, err := NewReviewer(kernel).ReviewPluginInstall(context.Background(), json.RawMessage(`{"id":"example"}`), "example", "1.0.0", approved)
	if err != nil {
		t.Fatalf("review: %v", err)
	}
	if len(review.Permissions) != 1 || review.Permissions[0] != "workspace.read" {
		t.Fatalf("permissions = %v", review.Permissions)
	}
	if len(review.Programs) != 1 || string(review.Programs[0]) != `{"kind":"runtime"}` {
		t.Fatalf("programs = %s", review.Programs)
	}
	if len(review.NewPrograms) != 1 || string(review.NewPrograms[0]) != `{"kind":"run"}` {
		t.Fatalf("new programs = %s", review.NewPrograms)
	}
	if kernel.reviewExpected != [2]string{"example", "1.0.0"} {
		t.Fatalf("expected = %v", kernel.reviewExpected)
	}
	if len(kernel.reviewApproved) != 1 {
		t.Fatalf("approved = %s", kernel.reviewApproved)
	}
	// The capabilities handed to Core must be the ones this client implements, not
	// what Core could parse.
	if len(kernel.reviewCaps["languages"]) != 2 {
		t.Fatalf("capabilities = %v", kernel.reviewCaps)
	}
}

func TestReviewerRefusesWithoutKernel(t *testing.T) {
	if _, err := NewReviewer(nil).ReviewPluginInstall(context.Background(), json.RawMessage(`{}`), "", "", nil); !errors.Is(err, ErrAssembly) {
		t.Fatalf("err = %v", err)
	}
}

func TestReviewerPropagatesCoreRefusal(t *testing.T) {
	refusal := errors.New("plugin.api.unsupported")
	kernel := &fakeKernel{reviewErr: refusal}
	if _, err := NewReviewer(kernel).ReviewPluginInstall(context.Background(), json.RawMessage(`{}`), "", "", nil); !errors.Is(err, refusal) {
		t.Fatalf("err = %v", err)
	}
}

// installedPackage writes an installed package holding manifest and files.
func installedPackage(t *testing.T, manifest string, files map[string]string) pluginmanager.Entry {
	t.Helper()
	directory := filepath.Join(t.TempDir(), "example", "1.0.0")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, pluginpkg.ManifestFile), []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
	for name, body := range files {
		path := filepath.Join(directory, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return pluginmanager.Entry{
		Installed: pluginpkg.Installed{ID: "example", Version: "1.0.0", Path: directory},
		Enabled:   true,
	}
}

const languageManifest = `{"id":"example","version":"1.0.0","languages":[{"id":"examplelang","displayName":"Example","fileExtensions":[".ex"],"fileNames":["Examplefile"],"grammar":{"kind":"textmate","path":"grammars/example.json"}}]}`

func TestLoadLanguagesMapsConfiguration(t *testing.T) {
	manifest := `{"id":"example","version":"1.0.0","languages":[{"id":"examplelang","displayName":"Example","fileExtensions":[".ex"],"configuration":{"lineComment":"//","blockComment":["/*","*/"],"brackets":[["{","}"],["[","]"]],"autoClosingPairs":[["(",")"]]}}]}`
	service, err := Open(&fakeKernel{}, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	languages, err := service.LoadLanguages(context.Background(), []pluginmanager.Entry{installedPackage(t, manifest, nil)})
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(languages) != 1 {
		t.Fatalf("languages = %+v", languages)
	}
	language := languages[0]
	if language.Comments.Line != "//" {
		t.Fatalf("line comment = %q", language.Comments.Line)
	}
	if language.Comments.Block.Open != "/*" || language.Comments.Block.Close != "*/" {
		t.Fatalf("block comment = %+v", language.Comments.Block)
	}
	if len(language.Brackets) != 2 || language.Brackets[1].Open != "[" {
		t.Fatalf("brackets = %+v", language.Brackets)
	}
	if len(language.AutoClosing) != 1 || language.AutoClosing[0].Close != ")" {
		t.Fatalf("auto closing = %+v", language.AutoClosing)
	}
	if len(language.Grammar) != 0 {
		t.Fatalf("a language without a grammar carries one: %s", language.Grammar)
	}
}

func TestDelimiterPairsDropsMalformedEntries(t *testing.T) {
	if pair, ok := delimiterPair([]string{"{", "}"}); !ok || pair.Open != "{" {
		t.Fatalf("pair = %+v, ok = %v", pair, ok)
	}
	for _, values := range [][]string{nil, {"{"}, {"{", "}", "}"}, {"", "}"}} {
		if _, ok := delimiterPair(values); ok {
			t.Fatalf("%v was accepted as a pair", values)
		}
	}
	if pairs := delimiterPairs(nil); pairs != nil {
		t.Fatalf("pairs = %+v", pairs)
	}
	if pairs := delimiterPairs([][]string{{"{"}}); pairs != nil {
		t.Fatalf("pairs = %+v", pairs)
	}
}

func TestLoadLanguagesReadsGrammarFromThePackage(t *testing.T) {
	kernel := &fakeKernel{}
	service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	entry := installedPackage(t, languageManifest, map[string]string{"grammars/example.json": `{"scopeName":"source.example"}`})
	languages, err := service.LoadLanguages(context.Background(), []pluginmanager.Entry{entry})
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(languages) != 1 {
		t.Fatalf("languages = %+v", languages)
	}
	language := languages[0]
	if language.ID != "examplelang" {
		t.Fatalf("id = %q", language.ID)
	}
	if len(language.Extensions) != 1 || language.Extensions[0] != ".ex" {
		t.Fatalf("extensions = %v", language.Extensions)
	}
	if string(language.Grammar) != `{"scopeName":"source.example"}` {
		t.Fatalf("grammar = %s", language.Grammar)
	}
	if len(kernel.decoded) != 1 || kernel.decoded[0] != "examplelang" {
		t.Fatalf("decoded = %v", kernel.decoded)
	}
}

func TestLoadLanguagesSkipsDisabledPlugins(t *testing.T) {
	service, err := Open(&fakeKernel{}, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	entry := installedPackage(t, languageManifest, map[string]string{"grammars/example.json": `{}`})
	entry.Enabled = false
	languages, err := service.LoadLanguages(context.Background(), []pluginmanager.Entry{entry})
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(languages) != 0 {
		t.Fatalf("a disabled plugin contributed %+v", languages)
	}
}

func TestLoadLanguagesReportsABrokenPackage(t *testing.T) {
	service, err := Open(&fakeKernel{}, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	broken := pluginmanager.Entry{
		Installed: pluginpkg.Installed{ID: "broken", Version: "1.0.0", Path: filepath.Join(t.TempDir(), "absent")},
		Enabled:   true,
	}
	healthy := installedPackage(t, languageManifest, map[string]string{"grammars/example.json": `{}`})
	languages, err := service.LoadLanguages(context.Background(), []pluginmanager.Entry{broken, healthy})
	if !errors.Is(err, ErrPackageRead) {
		t.Fatalf("err = %v", err)
	}
	if len(languages) != 1 {
		t.Fatalf("a broken plugin stopped the healthy one: %+v", languages)
	}
}

func TestLoadLanguagesReportsARejectedGrammar(t *testing.T) {
	refusal := errors.New("grammar rejected")
	service, err := Open(&fakeKernel{grammarErr: refusal}, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	entry := installedPackage(t, languageManifest, map[string]string{"grammars/example.json": `{}`})
	languages, err := service.LoadLanguages(context.Background(), []pluginmanager.Entry{entry})
	if !errors.Is(err, refusal) {
		t.Fatalf("err = %v", err)
	}
	// The contract has a language whose grammar is refused open as plain text while
	// the rest of the plugin keeps working, so the language is still registered.
	if len(languages) != 1 {
		t.Fatalf("languages = %+v", languages)
	}
	if len(languages[0].Grammar) != 0 {
		t.Fatalf("a rejected grammar was registered: %s", languages[0].Grammar)
	}
}

func TestLoadLanguagesReportsALanguageWithNoMatchingRule(t *testing.T) {
	manifest := `{"id":"example","version":"1.0.0","languages":[{"id":"examplelang","displayName":"Example","grammar":{"kind":"textmate","path":"grammars/example.json"}}]}`
	service, err := Open(&fakeKernel{}, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	entry := installedPackage(t, manifest, map[string]string{"grammars/example.json": `{}`})
	languages, err := service.LoadLanguages(context.Background(), []pluginmanager.Entry{entry})
	if err == nil {
		t.Fatal("a language the editor could never match was accepted")
	}
	if len(languages) != 0 {
		t.Fatalf("languages = %+v", languages)
	}
}

func TestLoadLanguagesRefusesAnEscapingGrammarPath(t *testing.T) {
	manifest := `{"id":"example","version":"1.0.0","languages":[{"id":"examplelang","displayName":"Example","grammar":{"kind":"textmate","path":"../outside.json"}}]}`
	service, err := Open(&fakeKernel{}, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	entry := installedPackage(t, manifest, nil)
	languages, err := service.LoadLanguages(context.Background(), []pluginmanager.Entry{entry})
	if err == nil {
		t.Fatal("a grammar outside the package was accepted")
	}
	if len(languages) != 0 {
		t.Fatalf("languages = %+v", languages)
	}
}
