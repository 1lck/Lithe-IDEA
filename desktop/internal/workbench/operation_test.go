package workbench

import (
	"context"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logwindow"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// opRecordingLog keeps each record with the op it was written under.
type opRecordingLog struct {
	logwindow.Source
	mu      sync.Mutex
	records []opRecord
}

type opRecord struct{ event, op string }

func (l *opRecordingLog) Emit(level core.LogLevel, event, op string, fields map[string]any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.records = append(l.records, opRecord{event: event, op: op})
}

// ops is the op of each record of event, in the order they were written.
func (l *opRecordingLog) ops(event string) []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	var ops []string
	for _, record := range l.records {
		if record.event == event {
			ops = append(ops, record.op)
		}
	}
	return ops
}

// TestUserActionCarriesItsOpToItsWorkAndResult starts an action in a window callback that
// starts background work, and checks that the action's record, the work's record, the context
// the work sends Core requests with and the result applied on the window thread share the op,
// and that the op ends with the callback and with the result.
func TestUserActionCarriesItsOpToItsWorkAndResult(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	a := h.app
	logger := &opRecordingLog{}
	a.logSink = logger
	var origin core.Origin
	var opDuringResult operation
	config := a.operating(app.Config{OnKey: func(gfx.KeyEvent) gfx.EventResult {
		a.performed("test.action", surfaceShortcut)
		a.background(nil, 0, func(ctx context.Context) func(*App) {
			origin = core.OriginOf(ctx)
			a.emitIn(ctx, core.LevelInfo, "test.work", nil)
			return func(a *App) {
				opDuringResult = a.op
				a.emit(core.LevelInfo, "test.result", nil)
			}
		})
		return gfx.EventResult{}
	}})
	config.OnKey(gfx.KeyEvent{})
	if a.op != (operation{}) {
		t.Fatalf("the action %+v outlived the callback that started it", a.op)
	}
	a.emit(core.LevelInfo, "test.after", nil)
	h.settle()

	performed := logger.ops("app.action.performed")
	if len(performed) != 1 || performed[0] == "" {
		t.Fatalf("app.action.performed ops = %q, want one op", performed)
	}
	op := performed[0]
	if got := logger.ops("test.work"); len(got) != 1 || got[0] != op {
		t.Errorf("the work's record ops = %q, want %q", got, op)
	}
	if got := logger.ops("test.result"); len(got) != 1 || got[0] != op {
		t.Errorf("the result's record ops = %q, want %q", got, op)
	}
	if got := logger.ops("test.after"); len(got) != 1 || got[0] != "" {
		t.Errorf("a record after the callback has ops %q, want none", got)
	}
	if want := (core.Origin{Operation: op, Trigger: "test.action"}); origin != want {
		t.Errorf("the work's requests report %+v, want %+v", origin, want)
	}
	if opDuringResult.id != op {
		t.Errorf("the result ran under %+v, want op %q", opDuringResult, op)
	}
	if a.op != (operation{}) {
		t.Errorf("the action %+v outlived its result", a.op)
	}
}

// TestBackgroundWorkWithoutAnActionHasNoOp checks that work started outside an action sends
// requests that belong to no action and applies its result under none.
func TestBackgroundWorkWithoutAnActionHasNoOp(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	a := h.app
	logger := &opRecordingLog{}
	a.logSink = logger
	var origin core.Origin
	a.background(nil, 0, func(ctx context.Context) func(*App) {
		origin = core.OriginOf(ctx)
		return func(a *App) { a.emit(core.LevelInfo, "test.result", nil) }
	})
	h.settle()
	if origin != (core.Origin{}) {
		t.Errorf("work outside an action reports %+v", origin)
	}
	if got := logger.ops("test.result"); len(got) != 1 || got[0] != "" {
		t.Errorf("the result's record ops = %q, want none", got)
	}
}

// operationAccessors are the App methods that read or set a.op, which only the window thread
// may do.
var operationAccessors = []string{"emit", "performed", "operationContext", "within", "endOperation"}

// TestOperationIsOnlyUsedOnTheWindowThread finds the App methods that can run off the window
// thread and fails when one of them reads or sets the action in progress: a go statement's
// function, the work given to background and every App method they call run off it, except the
// functions they hand back to the window thread (func(*App) results and the functions given to
// windowRunners). Such code records with emitIn and the work's context instead.
func TestOperationIsOnlyUsedOnTheWindowThread(t *testing.T) {
	paths, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	// calls is, for each App method, the App methods its window-thread part calls.
	calls := map[string]map[string][]token.Pos{}
	// offThread is where each App method is called off the window thread directly.
	offThread := map[string][]token.Pos{}
	for _, path := range paths {
		if strings.HasSuffix(path, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Body == nil {
				continue
			}
			mine := map[string][]token.Pos{}
			if isAppMethod(fn) {
				calls[fn.Name.Name] = mine
			}
			var walk func(node ast.Node, off, record bool)
			walk = func(node ast.Node, off, record bool) {
				ast.Inspect(node, func(n ast.Node) bool {
					switch x := n.(type) {
					case *ast.GoStmt:
						if lit, ok := x.Call.Fun.(*ast.FuncLit); ok {
							walk(lit.Body, true, false)
							for _, arg := range x.Call.Args {
								walk(arg, off, record)
							}
							return false
						}
						if sel, ok := x.Call.Fun.(*ast.SelectorExpr); ok && isReceiver(sel.X) {
							offThread[sel.Sel.Name] = append(offThread[sel.Sel.Name], x.Pos())
						}
					case *ast.FuncLit:
						if isApply(x) {
							// An apply function runs on the window thread whoever made it.
							walk(x.Body, false, false)
							return false
						}
					case *ast.CallExpr:
						sel, ok := x.Fun.(*ast.SelectorExpr)
						if !ok {
							return true
						}
						if windowRunners[sel.Sel.Name] && isReceiver(sel.X) {
							for _, arg := range x.Args {
								if lit, ok := arg.(*ast.FuncLit); ok {
									walk(lit.Body, false, false)
								} else {
									walk(arg, off, record)
								}
							}
							return false
						}
						if sel.Sel.Name == "background" && len(x.Args) == 3 {
							if lit, ok := x.Args[2].(*ast.FuncLit); ok {
								walk(x.Args[0], off, record)
								walk(lit.Body, true, false)
								return false
							}
						}
						if !isReceiver(sel.X) {
							return true
						}
						if off {
							offThread[sel.Sel.Name] = append(offThread[sel.Sel.Name], x.Pos())
						} else if record {
							mine[sel.Sel.Name] = append(mine[sel.Sel.Name], x.Pos())
						}
					}
					return true
				})
			}
			walk(fn.Body, false, true)
		}
	}
	// An App method called off the window thread runs its window-thread part off it too.
	why := map[string]string{}
	var queue []string
	for name, where := range offThread {
		if _, ok := calls[name]; ok {
			why[name] = "called off the window thread at " + fset.Position(where[0]).String()
			queue = append(queue, name)
		}
	}
	for len(queue) > 0 {
		name := queue[0]
		queue = queue[1:]
		for callee := range calls[name] {
			if _, ok := calls[callee]; !ok {
				continue
			}
			if _, seen := why[callee]; seen {
				continue
			}
			why[callee] = "called by " + name
			queue = append(queue, callee)
		}
	}
	var found []string
	for _, accessor := range operationAccessors {
		for _, pos := range offThread[accessor] {
			found = append(found, fmt.Sprintf("%s: %s off the window thread", fset.Position(pos), accessor))
		}
		for name, reason := range why {
			for _, pos := range calls[name][accessor] {
				found = append(found, fmt.Sprintf("%s: %s calls %s and is %s", fset.Position(pos), name, accessor, reason))
			}
		}
	}
	sort.Strings(found)
	for _, line := range found {
		t.Error(line)
	}
}

// windowRunners are the App methods that run the functions they are given on the window thread.
var windowRunners = map[string]bool{"post": true, "ideAPIOnProject": true, "ideAPIOnProjectLater": true, "ideAPIAwaitLaunch": true}

func isAppMethod(fn *ast.FuncDecl) bool {
	if fn.Recv == nil || len(fn.Recv.List) != 1 {
		return false
	}
	star, ok := fn.Recv.List[0].Type.(*ast.StarExpr)
	if !ok {
		return false
	}
	id, ok := star.X.(*ast.Ident)
	return ok && id.Name == "App"
}

// isApply reports whether lit is a func(*App), which the window thread runs.
func isApply(lit *ast.FuncLit) bool {
	params := lit.Type.Params.List
	if len(params) != 1 {
		return false
	}
	star, ok := params[0].Type.(*ast.StarExpr)
	if !ok {
		return false
	}
	id, ok := star.X.(*ast.Ident)
	return ok && id.Name == "App"
}

// isReceiver reports whether x is the workbench, which the package always names a.
func isReceiver(x ast.Expr) bool {
	id, ok := x.(*ast.Ident)
	return ok && id.Name == "a"
}
