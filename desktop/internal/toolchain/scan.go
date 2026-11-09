package toolchain

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"runtime"
	"sort"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// workspace holds the native facts one load may read. It is confined to the
// opened project root and the declared scan roots.
type workspace struct {
	root          string
	home          string
	platform      string
	environment   map[string]string
	lookup        LookupFunc
	probe         ProbeFunc
	caseSensitive bool
	// entries bounds every scan this load performs, as Core's plan declares.
	entries int
	facts   map[string]core.ToolchainFileFact
	order   []string
}

func newWorkspace(root string, options Options) (*workspace, error) {
	if root == "" || !filepath.IsAbs(root) {
		return nil, errors.New("toolchain: the workspace root must be absolute")
	}
	canonicalRoot, err := canonicalPath(root)
	if err != nil {
		return nil, err
	}
	if info, err := os.Stat(canonicalRoot); err != nil || !info.IsDir() {
		return nil, errors.New("toolchain: the workspace root is not a directory")
	}
	home := options.Home
	if home == "" {
		if home, err = os.UserHomeDir(); err != nil {
			return nil, err
		}
	}
	environment := options.Environment
	if environment == nil {
		environment = currentEnvironment()
	}
	lookup := options.Lookup
	if lookup == nil {
		lookup = defaultLookup
	}
	probe := options.Probe
	if probe == nil {
		probe = defaultProbe
	}
	return &workspace{
		root:          canonicalRoot,
		home:          home,
		platform:      options.Platform,
		environment:   environment,
		lookup:        lookup,
		probe:         probe,
		caseSensitive: options.Platform != "windows",
		entries:       4096,
		facts:         make(map[string]core.ToolchainFileFact),
	}, nil
}

func currentEnvironment() map[string]string {
	result := make(map[string]string)
	for _, entry := range os.Environ() {
		if key, value, ok := strings.Cut(entry, "="); ok {
			result[key] = value
		}
	}
	return result
}

func defaultLookup(command string) (string, error) {
	return lookupPath(command)
}

var lookupPath = func(command string) (string, error) {
	found, err := exec.LookPath(command)
	if err != nil {
		return "", err
	}
	return canonicalPath(found)
}

func executableMode(info os.FileInfo) bool {
	return runtime.GOOS == "windows" || info.Mode().Perm()&0o111 != 0
}

// canonicalPath resolves every symbolic link. Missing paths keep the cleaned
// absolute spelling, which is still enough evidence for Core to see "missing".
func canonicalPath(name string) (string, error) {
	absolute, err := filepath.Abs(name)
	if err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err == nil {
		return resolved, nil
	}
	if errors.Is(err, os.ErrNotExist) {
		return filepath.Clean(absolute), nil
	}
	return "", err
}

func (w *workspace) insideRoot(name string) bool {
	root := w.root
	candidate := name
	if !w.caseSensitive {
		root = strings.ToLower(root)
		candidate = strings.ToLower(candidate)
	}
	relative, err := filepath.Rel(root, candidate)
	if err != nil {
		return false
	}
	return relative == "." || (relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)))
}

// observe records one native fact. Every fact is deduplicated by native identity
// so Core never sees two contradictory rows for one path.
func (w *workspace) observe(name string) core.ToolchainFileFact {
	absolute, err := filepath.Abs(name)
	if err != nil {
		return core.ToolchainFileFact{}
	}
	cleaned := filepath.Clean(absolute)
	key := cleaned
	if !w.caseSensitive {
		key = strings.ToLower(key)
	}
	if fact, ok := w.facts[key]; ok {
		return fact
	}
	fact := core.ToolchainFileFact{Path: cleaned, CanonicalPath: cleaned, Kind: "missing"}
	if info, statErr := os.Lstat(cleaned); statErr == nil {
		if resolved, linkErr := filepath.EvalSymlinks(cleaned); linkErr == nil {
			fact.CanonicalPath = resolved
			if target, targetErr := os.Stat(resolved); targetErr == nil {
				info = target
			}
		}
		switch {
		case info.Mode().IsRegular():
			fact.Kind = "file"
			fact.Executable = executableMode(info)
		case info.IsDir():
			fact.Kind = "directory"
		}
	}
	w.facts[key] = fact
	w.order = append(w.order, key)
	return fact
}

// all returns the facts in a stable order, which keeps Core's input comparable
// between two loads that observed the same native state.
func (w *workspace) all() []core.ToolchainFileFact {
	keys := append([]string(nil), w.order...)
	sort.Strings(keys)
	facts := make([]core.ToolchainFileFact, 0, len(keys))
	for _, key := range keys {
		facts = append(facts, w.facts[key])
	}
	return facts
}

func platformMatches(values []string, platform string) bool {
	if len(values) == 0 {
		return true
	}
	for _, value := range values {
		if value == platform {
			return true
		}
	}
	return false
}

// expandScans runs definition-owned scans. It knows no tool name: it expands the
// declared roots and single-component globs, follows links, and drops anything
// whose canonical home is workspace code.
func (w *workspace) expandScans(tool core.ToolchainDiscoveryPlanTool) ([]string, error) {
	var homes []string
	for _, scan := range tool.Scans {
		if !platformMatches(scan.Platforms, w.platform) {
			continue
		}
		root, ok := w.scanRoot(scan.Root)
		if !ok {
			continue
		}
		for _, entry := range w.expand(root, strings.Split(scan.Pattern, "/")) {
			home, ok := applyHomeLayouts(entry, tool.HomeLayouts, w.platform)
			if !ok {
				continue
			}
			canonical, err := canonicalPath(home)
			if err != nil {
				continue
			}
			if w.insideRoot(canonical) {
				continue
			}
			if info, statErr := os.Stat(canonical); statErr != nil || !info.IsDir() {
				continue
			}
			homes = append(homes, canonical)
		}
	}
	return uniqueSorted(homes), nil
}

func (w *workspace) scanRoot(root core.ToolchainDiscoveryRoot) (string, bool) {
	switch root.Kind {
	case "home":
		if w.home == "" || !filepath.IsAbs(w.home) {
			return "", false
		}
		return filepath.Clean(w.home), true
	case "environment":
		value := w.environment[root.Variable]
		if value == "" || !filepath.IsAbs(value) {
			return "", false
		}
		return filepath.Clean(value), true
	case "absolute":
		if !filepath.IsAbs(root.Path) {
			return "", false
		}
		return filepath.Clean(root.Path), true
	}
	return "", false
}

// expand walks one declared pattern. Each component is either literal or a
// single-name glob; `*` never crosses a separator. Hidden entries match only a
// component that itself starts with a dot.
func (w *workspace) expand(root string, components []string) []string {
	current := []string{root}
	for _, component := range components {
		var next []string
		globbed := strings.Contains(component, "*")
		hidden := strings.HasPrefix(component, ".")
		for _, directory := range current {
			if !globbed {
				candidate := filepath.Join(directory, component)
				if _, err := os.Lstat(candidate); err == nil {
					next = append(next, candidate)
				}
				continue
			}
			entries, err := os.ReadDir(directory)
			if err != nil {
				continue
			}
			for _, entry := range entries {
				if w.entries <= 0 {
					return next
				}
				name := entry.Name()
				if !hidden && strings.HasPrefix(name, ".") {
					continue
				}
				matched, matchErr := path.Match(component, name)
				if matchErr != nil || !matched {
					continue
				}
				w.entries--
				next = append(next, filepath.Join(directory, name))
			}
		}
		current = next
		if len(current) == 0 {
			break
		}
	}
	return current
}

// applyHomeLayouts maps one discovered entry to its tool home. An entry that
// matches no declared layout is skipped; a definition without home layouts uses
// the entry itself.
func applyHomeLayouts(entry string, layouts []core.ToolchainHomeLayout, platform string) (string, bool) {
	if len(layouts) == 0 {
		return entry, true
	}
	base := filepath.Base(entry)
	for _, layout := range layouts {
		if !platformMatches(layout.Platforms, platform) {
			continue
		}
		matched, err := path.Match(layout.Match, base)
		if err != nil || !matched {
			continue
		}
		if layout.Home == "." {
			return entry, true
		}
		return filepath.Join(entry, filepath.FromSlash(layout.Home)), true
	}
	return "", false
}

func uniqueSorted(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	sort.Strings(values)
	result := values[:1]
	for _, value := range values[1:] {
		if value != result[len(result)-1] {
			result = append(result, value)
		}
	}
	return result
}

// executablePath is the first declared layout path that exists under home.
func executablePath(home string, layouts []core.ToolchainExecutableLayout, platform string) string {
	for _, layout := range layouts {
		if !platformMatches(layout.Platforms, platform) {
			continue
		}
		candidate := filepath.Join(home, filepath.FromSlash(layout.Path))
		if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() {
			return candidate
		}
	}
	return ""
}

// prependPath expands one declared `${home}` path template.
func prependPath(home, template string) (string, bool) {
	if template == "${home}" {
		return home, true
	}
	suffix, ok := strings.CutPrefix(template, "${home}/")
	if !ok {
		return "", false
	}
	return filepath.Join(home, filepath.FromSlash(suffix)), true
}

// probeAll runs the definition's version probe for every executable Core may
// select. Probes are bounded in count, concurrency and time, and every process
// is owned by this call.
func (w *workspace) probeAll(ctx context.Context, definition core.ToolchainToolDefinition, executables []string) []core.ToolchainProbe {
	// Core returns native absolute paths with portable separators. Pins and
	// filesystem discovery can name the same Windows file with backslashes or
	// different case. Probe each native identity once; Core rejects duplicates.
	seen := make(map[string]bool, len(executables))
	paths := make([]string, 0, len(executables))
	for _, executable := range uniqueSorted(executables) {
		cleaned := filepath.Clean(executable)
		key := cleaned
		if !w.caseSensitive {
			key = strings.ToLower(key)
		}
		if !seen[key] {
			seen[key] = true
			paths = append(paths, cleaned)
		}
	}
	executables = paths
	const maxProbes = 64
	if len(executables) > maxProbes {
		executables = executables[:maxProbes]
	}
	if len(executables) == 0 || len(definition.Version.Arguments) == 0 {
		return nil
	}
	probes := make([]core.ToolchainProbe, len(executables))
	workers := 4
	if len(executables) < workers {
		workers = len(executables)
	}
	jobs := make(chan int)
	done := make(chan struct{})
	for i := 0; i < workers; i++ {
		go func() {
			for index := range jobs {
				output, code, err := w.probe(ctx, executables[index], definition.Version.Arguments)
				if err != nil {
					code = -1
					output = ""
				}
				probes[index] = core.ToolchainProbe{Executable: executables[index], Output: output, ExitCode: code}
			}
			done <- struct{}{}
		}()
	}
	for index := range executables {
		if ctx.Err() != nil {
			break
		}
		jobs <- index
	}
	close(jobs)
	for i := 0; i < workers; i++ {
		<-done
	}
	// A cancelled load must not publish a partial probe set.
	if ctx.Err() != nil {
		return nil
	}
	filtered := probes[:0]
	for _, probe := range probes {
		if probe.Executable != "" {
			filtered = append(filtered, probe)
		}
	}
	return filtered
}
