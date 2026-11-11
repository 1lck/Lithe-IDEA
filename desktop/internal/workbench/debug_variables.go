package workbench

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

const (
	// debugVariablePageSize is how many children one variables request asks for.
	// Core plans the sequence of pages; the host only chooses their size.
	debugVariablePageSize = 100
)

// debugVarNode is one row of the variable tree: a scope, a variable or a child
// of one. Rows are the host's: Core keeps the page cursor and the adapter keeps
// the values.
type debugVarNode struct {
	name, value, typeName, evaluateName string
	// ref is the adapter's variablesReference; positive when the value has children.
	ref int64
	// named and indexed are the adapter-reported child counts.
	named, indexed int64
	// parentRef is the container the variable lives in, which setVariable needs;
	// zero for a scope.
	parentRef int64
	depth     int
	expanded  bool
	// container holds the children once the node was expanded.
	container *debugVarContainer
	// scope marks a top-level scope row.
	scope bool
	// moreFor marks the status row at the end of an expanded container: it
	// stands for the next page, or shows that one is loading or failed.
	moreFor *debugVarNode
	// id names the row to the Tree so it keeps its focus while rows open.
	id int
	// expensive scopes load only when the user opens them.
	expensive bool
}

// debugVarContainer is the children of one node and their page cursor.
type debugVarContainer struct {
	ref     int64
	planned bool
	page    core.DebugVariablePageState
	nodes   []*debugVarNode
	// seen fingerprints the children already shown, so Core can count the new
	// ones of a page and recognize an adapter that repeats one.
	seen map[string]struct{}
	// status is the row after the children while more pages exist.
	status   *debugVarNode
	loading  bool
	complete bool
	failure  string
}

// debugVariableEdit is the value being typed for the selected variable.
type debugVariableEdit struct {
	node  *debugVarNode
	field ui.Field
}

// debugVariables is the Variables section of the Debug tool window.
type debugVariables struct {
	// frame is the selected index into debugState.frames.
	frame   int
	scopes  []*debugVarNode
	loading bool
	failure string
	// rows is the flattened visible tree, rebuilt before each paint.
	rows []*debugVarNode
	tree ui.TreeState
	// selected is the variable row the edit field acts on.
	selected *debugVarNode
	edit     debugVariableEdit
	// json shows the loaded tree as JSON instead.
	json bool
	// jsonLines and jsonList render that text; version rises with every change
	// of the tree so the text is rebuilt only when it changed.
	jsonLines   []string
	jsonList    ui.ListState
	version     uint64
	jsonVersion uint64
	// pending maps an operation ID to the handlers of its result.
	pending map[string]debugOperationHandlers
	// sequence numbers the operations of this stop.
	sequence uint64
	// nextID hands out row ids; it only grows, so an id is never reused.
	nextID int
}

// reset forgets everything tied to one stop: a reference is only valid while the
// debuggee stays suspended.
func (v *debugVariables) reset() {
	json, pending, nextID, tree := v.json, v.pending, v.nextID, v.tree
	*v = debugVariables{json: json, pending: pending, nextID: nextID, tree: tree}
	for id := range v.pending {
		delete(v.pending, id)
	}
}

// debugVariableKey fingerprints a child by what identifies it on screen.
func debugVariableKey(name, value, typeName, evaluateName string, ref int64) string {
	return fmt.Sprintf("%s\x00%s\x00%s\x00%s\x00%d", name, value, typeName, evaluateName, ref)
}

// flatten lists the visible rows in tree order.
func (v *debugVariables) flatten() []*debugVarNode {
	rows := v.rows[:0]
	var walk func(nodes []*debugVarNode)
	walk = func(nodes []*debugVarNode) {
		for _, node := range nodes {
			rows = append(rows, node)
			if node.expanded && node.container != nil {
				walk(node.container.nodes)
				container := node.container
				if container.loading || container.failure != "" || (container.planned && !container.complete) {
					if container.status == nil {
						container.status = &debugVarNode{moreFor: node}
					}
					container.status.depth = node.depth + 1
					rows = append(rows, container.status)
				}
			}
		}
	}
	walk(v.scopes)
	v.rows = rows
	return rows
}

// debugOperationHandlers are what happens to one operation's answer. failed is
// optional: without it a refused request is shown as the Variables section's
// failure and nothing else changes.
type debugOperationHandlers struct {
	done   func(*App, core.DebugOperationResult)
	failed func(a *App, message string, transport bool)
}

// debugOperation queues one session operation and registers the handlers of its
// result. The operation ID is how Core correlates the answer, so the handlers
// are stored before the request is sent.
func (a *App) debugOperation(p *project, label string, call func(ctx context.Context, session *debugSession, operationID string) (core.DebugUpdate, error), handlers debugOperationHandlers) {
	if p == nil || p.debug.activeSession() == nil {
		return
	}
	session := p.debug.activeSession()
	vars := &p.debug.vars
	vars.sequence++
	operationID := fmt.Sprintf("%s-%s-%d", session.id, label, vars.sequence)
	if vars.pending == nil {
		vars.pending = make(map[string]debugOperationHandlers)
	}
	vars.pending[operationID] = handlers
	a.background(p, debugOperationTimeout, func(ctx context.Context) func(*App) {
		session.operationMu.Lock()
		defer session.operationMu.Unlock()
		if session.stopped.Load() {
			return nil
		}
		update, err := call(ctx, session, operationID)
		if err != nil {
			return func(a *App) {
				delete(p.debug.vars.pending, operationID)
				a.finishDebugOperationError(p, session, handlers, err)
			}
		}
		if err := session.writeFrames(update.OutboundFrames); err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		a.postDebugUpdate(p, session, update)
		return nil
	})
}

// finishDebugOperationError shows a failed inspect or edit without ending the
// session: the adapter is still there, only this request was refused.
func (a *App) finishDebugOperationError(p *project, session *debugSession, handlers debugOperationHandlers, err error) {
	if a.project != p || !p.debug.hasSession(session) || errors.Is(err, context.Canceled) {
		return
	}
	defer p.debug.bindSession(session)()
	if handlers.failed != nil {
		handlers.failed(a, err.Error(), true)
		return
	}
	p.debug.vars.failure = err.Error()
}

// completeDebugOperation hands a finished operation's result to its handler and
// reports whether the operation was one of these (the rest are the stack's).
func (a *App) completeDebugOperation(p *project, event core.DebugEvent) bool {
	vars := &p.debug.vars
	handlers, ok := vars.pending[event.OperationID]
	if !ok {
		return false
	}
	delete(vars.pending, event.OperationID)
	switch event.Type {
	case "operationCompleted":
		if event.Result != nil && handlers.done != nil {
			handlers.done(a, *event.Result)
		}
	case "operationFailed":
		if handlers.failed != nil {
			handlers.failed(a, event.Message, false)
			return true
		}
		vars.failure = event.Message
		vars.loading = false
		if p.debug.activeSession() != nil {
			markDebugContainersFailed(vars, event.Message)
		}
	}
	return true
}

// markDebugContainersFailed stops the spinner of every container whose page was
// in flight, so a refused request does not leave a row loading forever.
func markDebugContainersFailed(v *debugVariables, message string) {
	var walk func(nodes []*debugVarNode)
	walk = func(nodes []*debugVarNode) {
		for _, node := range nodes {
			if node.container != nil {
				if node.container.loading {
					node.container.loading = false
					node.container.failure = message
				}
				walk(node.container.nodes)
			}
		}
	}
	walk(v.scopes)
}

// selectDebugFrame makes one stack frame current and loads its scopes.
func (a *App) selectDebugFrame(p *project, index int) {
	d := &p.debug
	if d.activeSession() == nil || index < 0 || index >= len(d.frames) {
		return
	}
	d.vars.reset()
	d.memory.reset()
	d.vars.frame = index
	d.vars.loading = true
	frameID := d.frames[index].ID
	a.debugOperation(p, "scopes", func(ctx context.Context, session *debugSession, operationID string) (core.DebugUpdate, error) {
		return a.kernel.InspectDebug(ctx, core.DebugInspectRequest{SessionID: session.id, OperationID: operationID, Kind: "scopes", FrameID: &frameID})
	}, debugOperationHandlers{done: func(a *App, result core.DebugOperationResult) {
		if p.debug.vars.frame != index || result.Kind != "scopes" {
			return
		}
		p.debug.vars.loading = false
		scopes := make([]*debugVarNode, 0, len(result.Scopes))
		for _, scope := range result.Scopes {
			scopes = append(scopes, &debugVarNode{
				name: scope.Name, ref: scope.VariablesReference, named: scope.NamedVariables, indexed: scope.IndexedVariables,
				scope: true, expensive: scope.Expensive,
			})
		}
		p.debug.vars.scopes = scopes
		p.debug.vars.version++
		// The locals open by themselves; an expensive scope waits for the user.
		for _, scope := range scopes {
			if !scope.expensive {
				a.expandDebugNode(p, scope)
				break
			}
		}
	}})
}

// expandDebugNode opens a row and loads its first page of children.
func (a *App) expandDebugNode(p *project, node *debugVarNode) {
	if node.ref <= 0 {
		return
	}
	node.expanded = true
	p.debug.vars.version++
	if node.container == nil {
		node.container = &debugVarContainer{ref: node.ref, seen: make(map[string]struct{})}
	}
	a.loadDebugContainer(p, node)
}

// collapseDebugNode closes a row; its loaded children are kept for the next open.
func (a *App) collapseDebugNode(p *project, node *debugVarNode) {
	node.expanded = false
	p.debug.vars.version++
}

// loadDebugContainer asks for the next page of a node's children: the first call
// plans the cursor through Core, every later one follows the cursor's next window.
func (a *App) loadDebugContainer(p *project, node *debugVarNode) {
	container := node.container
	if container == nil || container.loading || container.complete || p.debug.activeSession() == nil {
		return
	}
	container.loading, container.failure = true, ""
	session := p.debug.activeSession()
	if !container.planned {
		a.background(p, debugOperationTimeout, func(ctx context.Context) func(*App) {
			state, err := a.kernel.PlanDebugVariablePage(ctx, container.ref, node.named, node.indexed, debugVariablePageSize)
			return func(a *App) {
				if a.project != p || !p.debug.hasSession(session) {
					return
				}
				defer p.debug.bindSession(session)()
				container.loading = false
				if err != nil {
					container.failure = err.Error()
					return
				}
				container.page, container.planned = state, true
				a.loadDebugContainer(p, node)
			}
		})
		return
	}
	if container.page.Next == nil {
		container.loading, container.complete = false, true
		return
	}
	requested := *container.page.Next
	start, count, reference := int64(requested.Start), int64(requested.Count), container.ref
	a.debugOperation(p, "variables", func(ctx context.Context, session *debugSession, operationID string) (core.DebugUpdate, error) {
		return a.kernel.InspectDebug(ctx, core.DebugInspectRequest{
			SessionID: session.id, OperationID: operationID, Kind: "variables",
			VariablesReference: &reference, VariableFilter: requested.Filter, Start: &start, Count: &count,
		})
	}, debugOperationHandlers{done: func(a *App, result core.DebugOperationResult) {
		if result.Kind != "variables" {
			container.loading = false
			return
		}
		a.reduceDebugVariablePage(p, node, requested, result.Variables)
	}, failed: func(a *App, message string, _ bool) {
		container.loading, container.failure = false, message
	}})
}

// reduceDebugVariablePage lets Core decide whether a returned page is kept and
// whether the container is exhausted.
func (a *App) reduceDebugVariablePage(p *project, node *debugVarNode, requested core.DebugVariablePageRequest, page []core.DebugVariable) {
	container, session := node.container, p.debug.activeSession()
	items := make([]core.DebugVariablePageItem, 0, len(page))
	fresh := uint64(0)
	for _, variable := range page {
		items = append(items, core.DebugVariablePageItem{
			Name: variable.Name, Value: variable.Value, Type: variable.Type,
			EvaluateName: variable.EvaluateName, VariablesReference: variable.VariablesReference,
		})
		key := debugVariableKey(variable.Name, variable.Value, variable.Type, variable.EvaluateName, variable.VariablesReference)
		if _, known := container.seen[key]; !known {
			fresh++
		}
	}
	state := container.page
	a.background(p, debugOperationTimeout, func(ctx context.Context) func(*App) {
		accept, next, err := a.kernel.ReduceDebugVariablePage(ctx, state, requested, items, fresh)
		return func(a *App) {
			if a.project != p || !p.debug.hasSession(session) {
				return
			}
			defer p.debug.bindSession(session)()
			container.loading = false
			if err != nil {
				container.failure = err.Error()
				return
			}
			container.page = next
			if accept {
				for _, variable := range page {
					key := debugVariableKey(variable.Name, variable.Value, variable.Type, variable.EvaluateName, variable.VariablesReference)
					if _, known := container.seen[key]; known {
						continue
					}
					container.seen[key] = struct{}{}
					container.nodes = append(container.nodes, &debugVarNode{
						name: variable.Name, value: variable.Value, typeName: variable.Type, evaluateName: variable.EvaluateName,
						ref: variable.VariablesReference, named: variable.NamedVariables, indexed: variable.IndexedVariables,
						parentRef: container.ref, depth: node.depth + 1,
					})
				}
				p.debug.vars.version++
			}
			if next.Next == nil {
				container.complete = true
			}
		}
	})
}

// canEditDebugVariable reports whether the selected row can be given a new
// value: Core allows setVariable only while paused and when the adapter
// advertised it, so the host only mirrors that rule to enable the control.
func canEditDebugVariable(d *debugState, node *debugVarNode) bool {
	return node != nil && !node.scope && node.parentRef > 0 && d.state == "paused" &&
		d.capabilities != nil && d.capabilities.SupportsSetVariable
}

// setDebugVariable replaces the selected variable's value in its container.
func (a *App) setDebugVariable(p *project, node *debugVarNode, text string) {
	if !canEditDebugVariable(&p.debug, node) {
		return
	}
	text = strings.TrimSpace(text)
	parent, name := node.parentRef, node.name
	a.debugOperation(p, "setVariable", func(ctx context.Context, session *debugSession, operationID string) (core.DebugUpdate, error) {
		return a.kernel.SetDebugVariable(ctx, session.id, operationID, parent, name, text)
	}, debugOperationHandlers{done: func(a *App, result core.DebugOperationResult) {
		if result.Kind != "setVariable" || result.Variable == nil {
			return
		}
		replaced := result.Variable
		node.value, node.typeName, node.ref = replaced.Value, replaced.Type, replaced.VariablesReference
		node.named, node.indexed = replaced.NamedVariables, replaced.IndexedVariables
		// The old children described the old value.
		node.expanded, node.container = false, nil
		p.debug.vars.version++
	}})
}
