package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// pausedDebugSession starts the fixture adapter and waits until the debuggee is
// paused with its frames and the first scope's variables loaded.
func pausedDebugSession(t *testing.T) (*harness, *project) {
	t.Helper()
	h := debugHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "debug.marker"), []byte("debug\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "tests"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "tests", "debug_source.go"), []byte("package tests\n\nfunc main() {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := openDebugPanel(t, h, root)
	h.clickNamed(h.app.text.Debug.Start)
	awaitStateWithin(t, h, 30*time.Second, "the paused debuggee with its variables", func() bool {
		if p.debug.failure != "" {
			t.Fatalf("debug start failed: %s", p.debug.failure)
		}
		v := &p.debug.vars
		return p.debug.state == "paused" && len(v.scopes) == 2 && v.scopes[0].container != nil && len(v.scopes[0].container.nodes) == 3
	})
	return h, p
}

func findDebugVariable(nodes []*debugVarNode, name string) *debugVarNode {
	for _, node := range nodes {
		if node.name == name {
			return node
		}
	}
	return nil
}

// TestDebugVariablesPageAndEditThroughCore drives the whole Variables section
// against the real adapter process and Core session: scopes load for the
// selected frame, a large container loads page by page by Core's cursor, the
// JSON view mirrors the loaded tree, and a variable can be given a new value.
func TestDebugVariablesPageAndEditThroughCore(t *testing.T) {
	h, p := pausedDebugSession(t)
	v := &p.debug.vars
	locals := v.scopes[0]
	if !locals.expanded || v.scopes[1].expanded || !v.scopes[1].expensive {
		t.Fatalf("the locals open by themselves and an expensive scope waits: %+v %+v", locals, v.scopes[1])
	}
	if caps := p.debug.capabilities; caps == nil || !caps.SupportsSetVariable || len(caps.ExceptionBreakpointFilters) != 2 {
		t.Fatalf("capabilities = %+v", caps)
	}

	items := findDebugVariable(locals.container.nodes, "items")
	h.app.expandDebugNode(p, items)
	awaitStateWithin(t, h, 20*time.Second, "the first page", func() bool {
		return items.container != nil && len(items.container.nodes) == debugVariablePageSize
	})
	if items.container.complete || items.container.page.Next == nil {
		t.Fatalf("a container of 250 is not exhausted after 100: %+v", items.container.page)
	}
	rows := v.flatten()
	if status := rows[len(rows)-1]; status.moreFor != items {
		t.Fatalf("the last row must offer the next page, got %+v", status)
	}
	for !items.container.complete {
		before := len(items.container.nodes)
		h.app.loadDebugContainer(p, items)
		awaitStateWithin(t, h, 20*time.Second, "the next page", func() bool {
			return !items.container.loading && (len(items.container.nodes) > before || items.container.complete)
		})
	}
	if len(items.container.nodes) != 250 || items.container.nodes[249].value != "498" {
		t.Fatalf("loaded %d children, last %+v", len(items.container.nodes), items.container.nodes[len(items.container.nodes)-1])
	}

	v.json = true
	h.settle()
	if !strings.Contains(debugJSONText(v.scopes), `"count": 1`) {
		t.Fatalf("the JSON view does not mirror the tree:\n%s", debugJSONText(v.scopes)[:200])
	}
	v.json = false

	count := findDebugVariable(locals.container.nodes, "count")
	v.selected = count
	if !canEditDebugVariable(&p.debug, count) || canEditDebugVariable(&p.debug, locals) {
		t.Fatal("only a variable of a container is editable while paused")
	}
	h.app.setDebugVariable(p, count, " 99 ")
	awaitStateWithin(t, h, 20*time.Second, "the replaced value", func() bool { return count.value == "99" })
	if p.debug.failure != "" || v.failure != "" {
		t.Fatalf("failure = %q / %q", p.debug.failure, v.failure)
	}

	h.app.stopDebugByUser(p)
	awaitStateWithin(t, h, 20*time.Second, "the stopped session", func() bool { return p.debug.session == nil })
	if len(v.scopes) != 0 {
		// Stop leaves the stop's variables to the next reset; they are never
		// shown without a session.
		if h.shows("count") {
			t.Fatal("variables are shown without a session")
		}
	}
}

// TestDebugExceptionFiltersAndDisassembly covers the adapter-declared exception
// filters kept by the project and the Core-paged instruction window.
func TestDebugExceptionFiltersAndDisassembly(t *testing.T) {
	h, p := pausedDebugSession(t)
	d := &p.debug
	uncaught, caught := d.capabilities.ExceptionBreakpointFilters[0], d.capabilities.ExceptionBreakpointFilters[1]
	if !d.exceptions.exceptionEnabled(uncaught) || d.exceptions.exceptionEnabled(caught) {
		t.Fatal("until the user chooses, the adapter's declared defaults show")
	}
	h.app.setDebugException(p, "caught", true)
	h.settle()
	if !d.exceptions.exceptionEnabled(caught) || d.failure != "" {
		t.Fatalf("exception choice not kept: %+v, failure %q", d.exceptions, d.failure)
	}

	if !canDisassemble(d) {
		t.Fatal("the fixture frame carries an instruction pointer and the adapter disassembles")
	}
	h.app.loadDisassembly(p)
	awaitStateWithin(t, h, 20*time.Second, "the instruction window", func() bool { return !d.disassembly.loading && len(d.disassembly.rows) > 0 })
	rows := d.disassembly.rows
	if len(rows) != debugDisassemblyFirstWindow || rows[debugDisassemblyBefore].Address != "0x1000" {
		t.Fatalf("window = %d rows, current %q", len(rows), rows[min(debugDisassemblyBefore, len(rows)-1)].Address)
	}
	first := rows[0].Address
	h.app.loadDisassemblyEdge(p, "before")
	awaitStateWithin(t, h, 20*time.Second, "earlier instructions", func() bool { return !d.disassembly.loading })
	if d.disassembly.rows[0].Address == first || len(d.disassembly.rows) <= len(rows) {
		t.Fatalf("no earlier instructions were added: %d rows", len(d.disassembly.rows))
	}
	h.app.stopDebugByUser(p)
	awaitStateWithin(t, h, 20*time.Second, "the stopped session", func() bool { return p.debug.session == nil })
}
