package core

import (
	"context"
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

// TestEveryLoggedEventIsAcceptedByTheKernel reads every production call that reaches a log
// store's Emit, works out from the source the level, event id and field keys it writes, and
// asks the kernel this client links to encode one such event per call. A misspelled id, a
// level other than the catalog's, a missing required field or a key the catalog does not know
// fails here, instead of being a record the writer drops at run time.
func TestEveryLoggedEventIsAcceptedByTheKernel(t *testing.T) {
	scan := scanLogSources(t, filepath.Join("..", ".."))
	catalog := readLogCatalog(t)
	forwarded := forwardedLogEvents(t, scan)

	var sites []logSite
	used := map[string]bool{}
	for _, site := range scan.sites() {
		if site.problem == "" {
			sites = append(sites, site)
			continue
		}
		cases, ok := forwarded[site.origin]
		if !ok {
			t.Errorf("%s: %s; log a constant event, or list what %s forwards in forwardedLogEvents",
				strings.Join(site.where, " → "), site.problem, site.origin)
			continue
		}
		if !used[site.origin] {
			used[site.origin] = true
			for _, c := range cases {
				c.where = site.where
				sites = append(sites, c)
			}
		}
	}
	for origin := range forwarded {
		if !used[origin] {
			t.Errorf("forwardedLogEvents lists %s, which no longer logs an event chosen at run time", origin)
		}
	}

	seen := map[string]bool{}
	for _, site := range sites {
		seen[site.event] = true
	}
	// The scan must keep finding the calls it was written against, or a change to how the
	// client logs would make this test pass by checking nothing.
	for _, event := range []string{"app.session.started", "app.action.performed", "app.notification.operation_failed",
		"app.notification.operation_rejected", "app.background.operation_failed", "app.settings.decode_failed"} {
		if !seen[event] {
			t.Errorf("the scan found no call that logs %s", event)
		}
	}
	checkActionSurfaces(t, scan, sites)

	c := NewClient()
	const batchSize = 64
	for start := 0; start < len(sites); start += batchSize {
		chunk := sites[start:min(start+batchSize, len(sites))]
		events := make([]LogEvent, len(chunk))
		for i, site := range chunk {
			fields := map[string]any{}
			for key, bound := range site.fields {
				fields[key] = catalog.value(site.event, key, bound)
			}
			events[i] = LogEvent{Ts: "2026-11-14T09:30:00.000Z", Level: site.level, Seq: uint64(start + i + 1), Event: site.event, Fields: fields}
		}
		batch, err := c.EncodeLogBatch(context.Background(), LogBatch{Events: events, ValidateCatalog: true})
		if err != nil {
			t.Fatalf("EncodeLogBatch: %v", err)
		}
		if len(batch.Results) != len(events) {
			t.Fatalf("EncodeLogBatch answered %d results for %d events", len(batch.Results), len(events))
		}
		for i, result := range batch.Results {
			if result.Error == nil {
				continue
			}
			site := chunk[i]
			keys := make([]string, 0, len(site.fields))
			for key := range site.fields {
				keys = append(keys, key)
			}
			sort.Strings(keys)
			t.Errorf("%s: the kernel rejects %s %s with fields %v: %s (%d)", strings.Join(site.where, " → "),
				site.level, site.event, keys, logRejection(result.Error.Code), result.Error.Code)
		}
	}
	t.Logf("checked %d logging calls against the kernel's catalog", len(sites))
}

// forwardedLogEvents lists, for each function that logs an event chosen at run time, every
// event its callers hand it. Functions are named as their directory and name; the ids come from
// the constants the senders use, so a renamed constant fails to resolve here.
func forwardedLogEvents(t *testing.T, scan *logScan) map[string][]logSite {
	errorKeys := func(more ...string) map[string]*logBound {
		fields := logErrorKeys("error")
		for _, key := range more {
			fields[key] = nil
		}
		return fields
	}
	return map[string][]logSite{
		// termview.Failure carries the event of a terminal failure to the workbench, which
		// logs a failed start as a warning and anything else at debug level.
		"internal/workbench.terminalFailed": {
			{level: LevelWarn, event: scan.constant(t, "internal/termview", "eventStartFailed"), fields: errorKeys("stage")},
			{level: LevelDebug, event: scan.constant(t, "internal/termview", "eventInputFailed"), fields: errorKeys("stage")},
		},
		// recordEngineFact relays the facts Core attaches to plugin session events. Core picks
		// them from its own catalog and checks them there before they leave it, so the client
		// chooses none of them and has nothing to list; copying Core's choice here would only
		// drift from it.
		"internal/workbench.recordEngineFact": nil,
	}
}

// actionEvent is the event a user action is recorded as; its surface field is a closed set.
const actionEvent = "app.action.performed"

// checkActionSurfaces holds the surface of every recorded user action to the closed set the
// catalog lists for it. The kernel only checks that a surface is a token, so a made-up one
// would be accepted and then split the action counts of a surface in two.
//
// The workbench's actionSurface constants must be exactly that set, and every surface a call
// shows in the source must be one of them. A surface read from a parameter no caller in the
// source supplies, such as an action handed around as a func(actionSurface), is typed
// actionSurface and so is one of the constants; converting a string to the type is the only
// way past that, and fails here.
func checkActionSurfaces(t *testing.T, scan *logScan, sites []logSite) {
	t.Helper()
	allowed := readActionSurfaces(t)
	pkg := scan.packages["internal/workbench"]
	if pkg == nil {
		t.Fatal("no package internal/workbench")
	}
	declared := map[string]bool{}
	for _, file := range pkg.files {
		for _, decl := range file.Decls {
			gen, ok := decl.(*ast.GenDecl)
			if !ok || gen.Tok != token.CONST {
				continue
			}
			for _, spec := range gen.Specs {
				values := spec.(*ast.ValueSpec)
				if typ, ok := values.Type.(*ast.Ident); !ok || typ.Name != "actionSurface" {
					continue
				}
				for _, name := range values.Names {
					text, ok := (&logFrame{scan: scan, pkg: pkg, busy: map[string]bool{}}).identText(name.Name)
					switch {
					case !ok:
						t.Errorf("%s: actionSurface %s is not a string constant", scan.position(name), name.Name)
					case !allowed[text]:
						t.Errorf("%s: actionSurface %s is %q, which the catalog does not list for %s", scan.position(name), name.Name, text, actionEvent)
					default:
						declared[text] = true
					}
				}
			}
		}
	}
	for surface := range allowed {
		if !declared[surface] {
			t.Errorf("the catalog lists surface %q for %s, but no actionSurface constant has it", surface, actionEvent)
		}
	}
	for _, p := range scan.packages {
		for _, file := range p.files {
			ast.Inspect(file, func(n ast.Node) bool {
				if call, ok := n.(*ast.CallExpr); ok {
					if fun, ok := call.Fun.(*ast.Ident); ok && fun.Name == "actionSurface" {
						t.Errorf("%s: converts a value to actionSurface; pass one of its constants", scan.position(call))
					}
				}
				return true
			})
		}
	}
	checked := 0
	for _, site := range sites {
		if site.event != actionEvent {
			continue
		}
		bound := site.fields["surface"]
		if bound == nil {
			t.Errorf("%s: logs %s without a surface the source shows", strings.Join(site.where, " → "), actionEvent)
			continue
		}
		text, ok := bound.frame.text(bound.expr)
		if !ok {
			continue
		}
		checked++
		if !allowed[text] {
			t.Errorf("%s: records surface %q, which the catalog does not list for %s", strings.Join(site.where, " → "), text, actionEvent)
		}
	}
	if checked == 0 {
		t.Errorf("no call to %s showed its surface; the check would pass by checking nothing", actionEvent)
	}
	t.Logf("checked the surface of %d user actions", checked)
}

// readActionSurfaces reads the surfaces the catalog lists in the description of the surface
// field of app.action.performed, written as "…: menu, shortcut, … or drag_drop".
func readActionSurfaces(t *testing.T) map[string]bool {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(contractfixture.CoreEventCatalog(), "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var file struct {
			Events []struct {
				ID     string `json:"id"`
				Fields map[string]struct {
					Description string `json:"description"`
				} `json:"fields"`
			} `json:"events"`
		}
		if err := json.Unmarshal(data, &file); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		for _, event := range file.Events {
			if event.ID != actionEvent {
				continue
			}
			_, list, ok := strings.Cut(event.Fields["surface"].Description, ": ")
			if !ok {
				t.Fatalf("%s: the surface field of %s does not list its values after a colon", path, actionEvent)
			}
			allowed := map[string]bool{}
			for _, part := range strings.Split(list, ", ") {
				for _, surface := range strings.Split(part, " or ") {
					allowed[strings.TrimSpace(surface)] = true
				}
			}
			return allowed
		}
	}
	t.Fatalf("the catalog has no event %s", actionEvent)
	return nil
}

// logRejection names a logging v2 rejection code.
func logRejection(code int) string {
	switch code {
	case -32053:
		return "unknown event"
	case -32054:
		return "missing field"
	case -32055:
		return "invalid field"
	case -32056:
		return "unknown field"
	case -32057:
		return "level differs from the catalog"
	case -32059:
		return "event owned by the kernel"
	}
	return "rejected"
}

// logCatalog maps each event id to its encoded field keys and their catalog types: a duration
// is written as <name>_ms, and an error as <name>, <name>_code and <name>_domain.
type logCatalog map[string]map[string]string

func readLogCatalog(t *testing.T) logCatalog {
	t.Helper()
	dir := contractfixture.CoreEventCatalog()
	paths, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil || len(paths) == 0 {
		t.Fatalf("no event catalog in %s: %v", dir, err)
	}
	catalog := logCatalog{}
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var file struct {
			Events []struct {
				ID     string `json:"id"`
				Fields map[string]struct {
					Type string `json:"type"`
				} `json:"fields"`
			} `json:"events"`
		}
		if err := json.Unmarshal(data, &file); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		for _, event := range file.Events {
			keys := map[string]string{}
			for name, field := range event.Fields {
				switch field.Type {
				case "duration":
					keys[name+"_ms"] = field.Type
				case "error":
					keys[name], keys[name+"_code"], keys[name+"_domain"] = field.Type, "token", "token"
				default:
					keys[name] = field.Type
				}
			}
			catalog[event.ID] = keys
		}
	}
	return catalog
}

// value is what the event carries under key: the constant the source writes when it shows one,
// otherwise a valid value of the catalog type, so the kernel judges the keys and the constants
// rather than made-up values. A key the catalog does not declare gets a string the kernel then
// rejects as unknown.
func (c logCatalog) value(event, key string, bound *logBound) any {
	kind, ok := c[event][key]
	if !ok {
		return "probe"
	}
	switch kind {
	case "int":
		return int64(1)
	case "bool":
		return true
	case "duration", "bytes":
		return uint64(1)
	}
	if bound != nil {
		if text, ok := bound.frame.text(bound.expr); ok && text != "" {
			return text
		}
	}
	switch kind {
	case "id":
		return "probe-1"
	case "version":
		return "1.0.0"
	case "path":
		return "/probe/path"
	case "token":
		return "probe"
	}
	return "probe failure"
}

// logScan is the client's production Go source, parsed for the calls that reach a log store.
type logScan struct {
	fset     *token.FileSet
	root     string
	packages map[string]*logPackage
	// sinks are the client functions that pass some of their parameters on to a log store.
	sinks map[*ast.FuncDecl]*logSink
}

// logPackage is one directory of production files.
type logPackage struct {
	dir    string
	files  []*ast.File
	consts map[string]ast.Expr
	funcs  map[string][]*ast.FuncDecl
}

// logSink is a client function whose parameters decide the level, the event, the field keys
// or a field constant of what it logs. calls are the calls in it that read those parameters;
// the function's callers supply them.
type logSink struct {
	pkg   *logPackage
	decl  *ast.FuncDecl
	calls []*ast.CallExpr
}

// logSite is one event a call writes.
type logSite struct {
	// where is the call chain from the function that chose the event down to the store.
	where []string
	// origin names that function as its directory and name.
	origin string
	level  LogLevel
	event  string
	// fields maps each key to the expression of its value, nil when the source builds it.
	fields map[string]*logBound
	// problem says why the source does not show the event; empty when it does.
	problem string
}

// logBound is an expression and the call frame it is read in.
type logBound struct {
	expr  ast.Expr
	frame *logFrame
}

// logFrame is one function being read, with the arguments its caller passed.
type logFrame struct {
	scan  *logScan
	pkg   *logPackage
	decl  *ast.FuncDecl
	args  map[string]logBound
	depth int
	busy  map[string]bool
	// parent is the frame of the caller; nil for the function that chose the event.
	parent *logFrame
	// hits collects the parameters read while no caller supplies them, when finding sinks.
	hits map[string]bool
}

func scanLogSources(t *testing.T, root string) *logScan {
	t.Helper()
	s := &logScan{fset: token.NewFileSet(), root: root, packages: map[string]*logPackage{}, sinks: map[*ast.FuncDecl]*logSink{}}
	for _, top := range []string{"cmd", "internal"} {
		err := filepath.WalkDir(filepath.Join(root, top), func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				if d.Name() == "testdata" {
					return filepath.SkipDir
				}
				return nil
			}
			if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
				return nil
			}
			file, err := parser.ParseFile(s.fset, path, nil, parser.SkipObjectResolution)
			if err != nil {
				return err
			}
			rel, err := filepath.Rel(root, filepath.Dir(path))
			if err != nil {
				return err
			}
			dir := filepath.ToSlash(rel)
			pkg := s.packages[dir]
			if pkg == nil {
				pkg = &logPackage{dir: dir, consts: map[string]ast.Expr{}, funcs: map[string][]*ast.FuncDecl{}}
				s.packages[dir] = pkg
			}
			pkg.files = append(pkg.files, file)
			for _, decl := range file.Decls {
				switch decl := decl.(type) {
				case *ast.GenDecl:
					if decl.Tok != token.CONST {
						continue
					}
					for _, spec := range decl.Specs {
						values := spec.(*ast.ValueSpec)
						for i, name := range values.Names {
							if i < len(values.Values) {
								pkg.consts[name.Name] = values.Values[i]
							}
						}
					}
				case *ast.FuncDecl:
					if decl.Body != nil {
						pkg.funcs[decl.Name.Name] = append(pkg.funcs[decl.Name.Name], decl)
					}
				}
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	return s
}

// constant is the string value of a package-level constant.
func (s *logScan) constant(t *testing.T, dir, name string) string {
	t.Helper()
	pkg := s.packages[dir]
	if pkg == nil {
		t.Fatalf("no package %s", dir)
	}
	text, ok := (&logFrame{scan: s, pkg: pkg, busy: map[string]bool{}}).identText(name)
	if !ok {
		t.Fatalf("%s has no string constant %s", dir, name)
	}
	return text
}

func (s *logScan) position(node ast.Node) string {
	p := s.fset.Position(node.Pos())
	rel, err := filepath.Rel(s.root, p.Filename)
	if err != nil {
		rel = p.Filename
	}
	return filepath.ToSlash(rel) + ":" + strconv.Itoa(p.Line)
}

// sites reads every call that logs, from the functions that choose what they log.
func (s *logScan) sites() []logSite {
	s.findSinks()
	dirs := make([]string, 0, len(s.packages))
	for dir := range s.packages {
		dirs = append(dirs, dir)
	}
	sort.Strings(dirs)
	var out []logSite
	for _, dir := range dirs {
		pkg := s.packages[dir]
		for _, file := range pkg.files {
			for _, decl := range file.Decls {
				fn, ok := decl.(*ast.FuncDecl)
				if !ok || fn.Body == nil {
					continue
				}
				sink := s.sinks[fn]
				// A function that is only ever called is read through its callers, which
				// supply the values; one that is also passed around is read on its own too.
				alone := sink == nil || s.escapes(pkg, fn)
				top := &logFrame{scan: s, pkg: pkg, decl: fn, busy: map[string]bool{}}
				for _, call := range s.calls(pkg, fn) {
					if !alone && slices.Contains(sink.calls, call) {
						continue
					}
					for _, site := range top.sites(call, nil) {
						site.origin = pkg.dir + "." + fn.Name.Name
						out = append(out, site)
					}
				}
			}
		}
	}
	return out
}

// findSinks marks, until nothing changes, every function with a call that logs whose level,
// event, field keys or field constants come from the function's own parameters: reading the
// call without a caller then reads one of them.
func (s *logScan) findSinks() {
	for changed := true; changed; {
		changed = false
		for _, pkg := range s.packages {
			for _, decls := range pkg.funcs {
				for _, fn := range decls {
					for _, call := range s.calls(pkg, fn) {
						if sink := s.sinks[fn]; sink != nil && slices.Contains(sink.calls, call) {
							continue
						}
						probe := &logFrame{scan: s, pkg: pkg, decl: fn, busy: map[string]bool{}, hits: map[string]bool{}}
						for _, site := range probe.sites(call, nil) {
							for _, bound := range site.fields {
								if bound != nil {
									bound.frame.text(bound.expr)
								}
							}
						}
						if len(probe.hits) == 0 {
							continue
						}
						sink := s.sinks[fn]
						if sink == nil {
							sink = &logSink{pkg: pkg, decl: fn}
							s.sinks[fn] = sink
						}
						sink.calls = append(sink.calls, call)
						changed = true
					}
				}
			}
		}
	}
}

// calls lists the calls in fn that log, directly or through a sink.
func (s *logScan) calls(pkg *logPackage, fn *ast.FuncDecl) []*ast.CallExpr {
	var out []*ast.CallExpr
	ast.Inspect(fn.Body, func(n ast.Node) bool {
		if call, ok := n.(*ast.CallExpr); ok {
			if _, ok := s.sinkCall(pkg, call); ok {
				out = append(out, call)
			}
		}
		return true
	})
	return out
}

// sinkCall returns the sinks call reaches; it reports a store's Emit(level, event, op, fields)
// as a call that logs with no sinks.
func (s *logScan) sinkCall(pkg *logPackage, call *ast.CallExpr) ([]*logSink, bool) {
	name, method := "", false
	switch fun := call.Fun.(type) {
	case *ast.SelectorExpr:
		if fun.Sel.Name == "Emit" && len(call.Args) == 4 {
			return nil, true
		}
		name, method = fun.Sel.Name, true
	case *ast.Ident:
		name = fun.Name
	default:
		return nil, false
	}
	var targets []*logSink
	for _, decl := range pkg.funcs[name] {
		sink := s.sinks[decl]
		if sink == nil || (decl.Recv != nil) != method || len(paramNames(decl)) != len(call.Args) {
			continue
		}
		targets = append(targets, sink)
	}
	return targets, len(targets) > 0
}

// escapes reports whether fn is never called by name, or is also used as a value, such as a
// callback handed to another component; its callers then cannot be read from the source.
func (s *logScan) escapes(pkg *logPackage, fn *ast.FuncDecl) bool {
	name, method := fn.Name.Name, fn.Recv != nil
	calls, values := 0, 0
	for _, file := range pkg.files {
		skip := map[ast.Node]bool{}
		ast.Inspect(file, func(n ast.Node) bool {
			switch n := n.(type) {
			case *ast.FuncDecl:
				skip[n.Name] = true
			case *ast.CallExpr:
				skip[n.Fun] = true
				if sel, ok := n.Fun.(*ast.SelectorExpr); ok {
					skip[sel.Sel] = true
					if method && sel.Sel.Name == name {
						calls++
					}
				} else if id, ok := n.Fun.(*ast.Ident); ok && !method && id.Name == name {
					calls++
				}
			case *ast.SelectorExpr:
				skip[n.Sel] = true
				if method && n.Sel.Name == name && !skip[n] {
					values++
				}
			case *ast.Ident:
				if !method && n.Name == name && !skip[n] {
					values++
				}
			}
			return true
		})
	}
	return calls == 0 || values > 0
}

func paramNames(decl *ast.FuncDecl) []string {
	var names []string
	for _, field := range decl.Type.Params.List {
		if len(field.Names) == 0 {
			names = append(names, "_")
		}
		for _, name := range field.Names {
			names = append(names, name.Name)
		}
	}
	return names
}

// logWrite is one assignment to a local variable.
type logWrite struct {
	// value is the assigned expression; nil when the source cannot say (a multi-value or
	// range assignment, or an operator assignment).
	value ast.Expr
	// key is set for name[key] = value.
	key ast.Expr
	// source is what an assignment without a value reads from.
	source ast.Expr
	// zero marks var name T with no value.
	zero bool
	// merged marks maps.Copy(name, value).
	merged bool
}

func writes(body *ast.BlockStmt, name string) []logWrite {
	var out []logWrite
	is := func(e ast.Expr) bool {
		id, ok := e.(*ast.Ident)
		return ok && id.Name == name
	}
	ast.Inspect(body, func(n ast.Node) bool {
		switch n := n.(type) {
		case *ast.AssignStmt:
			paired := len(n.Lhs) == len(n.Rhs) && (n.Tok == token.DEFINE || n.Tok == token.ASSIGN)
			for i, lhs := range n.Lhs {
				w := logWrite{source: n.Rhs[min(i, len(n.Rhs)-1)]}
				if paired {
					w = logWrite{value: n.Rhs[i]}
				}
				if is(lhs) {
					out = append(out, w)
				}
				if ix, ok := lhs.(*ast.IndexExpr); ok && is(ix.X) {
					w.key = ix.Index
					out = append(out, w)
				}
			}
		case *ast.ValueSpec:
			for i, id := range n.Names {
				switch {
				case id.Name != name:
				case len(n.Values) == 0:
					out = append(out, logWrite{zero: true})
				case len(n.Values) == len(n.Names):
					out = append(out, logWrite{value: n.Values[i]})
				default:
					out = append(out, logWrite{source: n.Values[0]})
				}
			}
		case *ast.RangeStmt:
			if (n.Key != nil && is(n.Key)) || (n.Value != nil && is(n.Value)) {
				out = append(out, logWrite{source: n.X})
			}
		case *ast.CallExpr:
			if sel, ok := n.Fun.(*ast.SelectorExpr); ok && sel.Sel.Name == "Copy" && len(n.Args) == 2 && is(n.Args[0]) {
				if pkg, ok := sel.X.(*ast.Ident); ok && pkg.Name == "maps" {
					out = append(out, logWrite{value: n.Args[1], merged: true})
				}
			}
		}
		return true
	})
	return out
}

// sites reads the events call writes in frame f.
func (f *logFrame) sites(call *ast.CallExpr, where []string) []logSite {
	where = append(slices.Clone(where), f.scan.position(call))
	if f.depth > 12 {
		return []logSite{{where: where, problem: "the call chain is too deep to follow"}}
	}
	targets, _ := f.scan.sinkCall(f.pkg, call)
	if len(targets) == 0 {
		site := logSite{where: where}
		level, levelOK := f.text(call.Args[0])
		event, eventOK := f.text(call.Args[1])
		fields, fieldsOK := f.fields(call.Args[3])
		switch {
		case !levelOK:
			site.problem = "the level is not a constant"
		case !eventOK:
			site.problem = "the event id is not a constant"
		case !fieldsOK:
			site.problem = "the field keys cannot be read from the source"
		}
		site.level, site.event, site.fields = LogLevel(level), event, fields
		return []logSite{site}
	}
	var out []logSite
	for _, target := range targets {
		// A function that reaches itself again logs through the calls already read at its
		// first entry.
		if f.active(target.decl) {
			continue
		}
		inner := f.enter(target.pkg, target.decl, call.Args)
		for _, c := range target.calls {
			out = append(out, inner.sites(c, where)...)
		}
	}
	return out
}

func (f *logFrame) enter(pkg *logPackage, decl *ast.FuncDecl, args []ast.Expr) *logFrame {
	bound := map[string]logBound{}
	for i, name := range paramNames(decl) {
		if name != "_" && i < len(args) {
			bound[name] = logBound{expr: args[i], frame: f}
		}
	}
	return &logFrame{scan: f.scan, pkg: pkg, decl: decl, args: bound, depth: f.depth + 1, busy: map[string]bool{}, parent: f}
}

// active reports whether decl is being read in f or one of its callers.
func (f *logFrame) active(decl *ast.FuncDecl) bool {
	for frame := f; frame != nil; frame = frame.parent {
		if frame.decl == decl {
			return true
		}
	}
	return false
}

func (f *logFrame) bind(expr ast.Expr) *logBound {
	if expr == nil {
		return nil
	}
	return &logBound{expr: expr, frame: f}
}

// hit records that the frame read a parameter no caller supplies.
func (f *logFrame) hit(name string) {
	if f.hits != nil {
		f.hits[name] = true
	}
}

func (f *logFrame) isParam(name string) bool {
	return f.decl != nil && slices.Contains(paramNames(f.decl), name)
}

// logLevelNames are the severity constants of this package, as other packages name them.
var logLevelNames = map[string]LogLevel{"LevelDebug": LevelDebug, "LevelInfo": LevelInfo, "LevelWarn": LevelWarn, "LevelError": LevelError}

// text is the string value of expr, when the source shows a single one.
func (f *logFrame) text(expr ast.Expr) (string, bool) {
	switch e := ast.Unparen(expr).(type) {
	case *ast.BasicLit:
		if e.Kind == token.STRING {
			text, err := strconv.Unquote(e.Value)
			return text, err == nil
		}
	case *ast.BinaryExpr:
		if e.Op == token.ADD {
			left, leftOK := f.text(e.X)
			right, rightOK := f.text(e.Y)
			return left + right, leftOK && rightOK
		}
	case *ast.SelectorExpr:
		if pkg, ok := e.X.(*ast.Ident); ok && pkg.Name == "core" {
			if level, ok := logLevelNames[e.Sel.Name]; ok {
				return string(level), true
			}
		}
	case *ast.Ident:
		return f.identText(e.Name)
	case *ast.CallExpr:
		// string(x) of a string-typed constant is that constant.
		if fun, ok := e.Fun.(*ast.Ident); ok && fun.Name == "string" && len(e.Args) == 1 {
			return f.text(e.Args[0])
		}
	}
	return "", false
}

func (f *logFrame) identText(name string) (string, bool) {
	if bound, ok := f.args[name]; ok {
		return bound.frame.text(bound.expr)
	}
	if f.decl != nil {
		if f.isParam(name) {
			f.hit(name)
			return "", false
		}
		if f.busy[name] {
			return "", false
		}
		if ws := writes(f.decl.Body, name); len(ws) > 0 {
			f.busy[name] = true
			defer delete(f.busy, name)
			var value string
			for i, w := range ws {
				if w.value == nil || w.key != nil || w.merged {
					return "", false
				}
				text, ok := f.text(w.value)
				if !ok || (i > 0 && text != value) {
					return "", false
				}
				value = text
			}
			return value, true
		}
	}
	if c, ok := f.pkg.consts[name]; ok {
		return (&logFrame{scan: f.scan, pkg: f.pkg, busy: map[string]bool{}}).text(c)
	}
	return "", false
}

// logErrorKeys are the keys LogErrorFields writes for an error field called name.
func logErrorKeys(name string) map[string]*logBound {
	return map[string]*logBound{name: nil, name + "_code": nil, name + "_domain": nil}
}

// fields returns the keys of the map expr builds, each with the expression of its value when
// the source shows one. Keys set on different branches are all included.
func (f *logFrame) fields(expr ast.Expr) (map[string]*logBound, bool) {
	if f.depth > 12 {
		return nil, false
	}
	switch e := ast.Unparen(expr).(type) {
	case *ast.Ident:
		if e.Name == "nil" {
			return map[string]*logBound{}, true
		}
		if bound, ok := f.args[e.Name]; ok {
			return bound.frame.fields(bound.expr)
		}
		if f.isParam(e.Name) {
			f.hit(e.Name)
			return nil, false
		}
		if f.decl == nil || f.busy[e.Name] {
			return nil, false
		}
		ws := writes(f.decl.Body, e.Name)
		if len(ws) == 0 {
			return nil, false
		}
		f.busy[e.Name] = true
		defer delete(f.busy, e.Name)
		out := map[string]*logBound{}
		for _, w := range ws {
			switch {
			case w.zero:
			case w.key != nil:
				key, ok := f.text(w.key)
				if !ok {
					return nil, false
				}
				out[key] = f.bind(w.value)
			case w.value != nil:
				more, ok := f.fields(w.value)
				if !ok {
					return nil, false
				}
				for key, value := range more {
					out[key] = value
				}
			default:
				return nil, false
			}
		}
		return out, true
	case *ast.CompositeLit:
		out := map[string]*logBound{}
		for _, elt := range e.Elts {
			kv, ok := elt.(*ast.KeyValueExpr)
			if !ok {
				return nil, false
			}
			key, ok := f.text(kv.Key)
			if !ok {
				return nil, false
			}
			out[key] = f.bind(kv.Value)
		}
		return out, true
	case *ast.CallExpr:
		return f.callFields(e)
	}
	return nil, false
}

// callFields reads the map a call returns: LogErrorFields, maps.Clone, or a function of the
// same package whose returns show their keys.
func (f *logFrame) callFields(call *ast.CallExpr) (map[string]*logBound, bool) {
	name, method := "", false
	switch fun := call.Fun.(type) {
	case *ast.SelectorExpr:
		if pkg, ok := fun.X.(*ast.Ident); ok {
			switch {
			case pkg.Name == "core" && fun.Sel.Name == "LogErrorFields":
				return logErrorKeys("error"), true
			case pkg.Name == "maps" && fun.Sel.Name == "Clone" && len(call.Args) == 1:
				return f.fields(call.Args[0])
			}
		}
		name, method = fun.Sel.Name, true
	case *ast.Ident:
		name = fun.Name
	default:
		return nil, false
	}
	out := map[string]*logBound{}
	found := false
	for _, decl := range f.pkg.funcs[name] {
		if (decl.Recv != nil) != method || len(paramNames(decl)) != len(call.Args) {
			continue
		}
		found = true
		inner := f.enter(f.pkg, decl, call.Args)
		var failed bool
		ast.Inspect(decl.Body, func(n ast.Node) bool {
			switch n := n.(type) {
			case *ast.FuncLit:
				return false
			case *ast.ReturnStmt:
				if len(n.Results) == 0 {
					failed = true
					return false
				}
				more, ok := inner.fields(n.Results[0])
				if !ok {
					failed = true
					return false
				}
				for key, value := range more {
					out[key] = value
				}
			}
			return true
		})
		if failed {
			return nil, false
		}
	}
	return out, found
}
