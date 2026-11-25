package workbench

import (
	"context"
	"encoding/json"
	"hash/fnv"
	"slices"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// The Build tool window on the right stripe: every build system the workspace uses, as one
// tree. A workspace can hold many of them (a nested checkout per module, one build tool beside
// another), so they are not tabs to switch between but groups the user opens and closes.
//
// Inside a group the tree is the build tool's own: Core lays it out from the loaded model
// (build.modelTree), with child projects nested under their parent and every project holding
// its task folders (a Maven project's lifecycle and plugins), its dependencies and its targets.
// A model with one root project shows that project's contents straight under the group, so
// the group row stands for it. The layout runs off the window thread, once per model and
// filter; the window thread only walks the nodes that are open.
//
// The window's actions act on one instance, the selected one (build.go): a click on a row of
// another group selects that group's instance first. The selected instance's group is open
// until the user closes it, and only its rows show a selection.
//
// A group's model is loaded when the group is open, a few at a time, so a workspace of many
// build systems does not start every build tool at once. A dependencies node starts closed:
// its tree is a command of the build tool, run only once the user opens it.

// buildModelLoadsAtOnce bounds the models loaded together for the open groups; the next one
// starts when one of them ends.
const buildModelLoadsAtOnce = 4

// buildTreeTimeout bounds one layout of a tree by Core, which reads only the model it is sent.
const buildTreeTimeout = 30 * time.Second

// buildGroupHeadings name every task group a build system files its tasks under; Core heads the
// folder of a task without a category with its group's name.
func buildGroupHeadings(language i18n.Language) map[string]string {
	return map[string]string{
		"lifecycle":     i18n.Shared(language, "desktop.build.group.lifecycle"),
		"build":         i18n.Shared(language, "desktop.build.group.build"),
		"test":          i18n.Shared(language, "desktop.build.group.test"),
		"run":           i18n.Shared(language, "desktop.build.group.run"),
		"verification":  i18n.Shared(language, "desktop.build.group.verification"),
		"documentation": i18n.Shared(language, "desktop.build.group.documentation"),
		"other":         i18n.Shared(language, "desktop.build.group.other"),
	}
}

// buildTree is one instance's tree as Core laid it out for one filter. version and
// optionFingerprint are the model version and effective option digest it came from
// (buildInstance.modelVersion, buildInstance.OptionFingerprint), query and language the filter
// and the language of its folder headings. targets finds a target node's target in that model by ID.
type buildTree struct {
	version           uint64
	optionFingerprint string
	query             string
	language          i18n.Language
	tree              core.BuildModelTree
	failed            string
	targets           map[string]int
}

// buildTrees are the trees of one instance: the whole tree and the latest filtered one, each
// with whether a layout of it is out. A filtered tree for an older query keeps showing until
// the layout for the current one arrives, so typing does not empty the window.
type buildTrees struct {
	whole, filtered       *buildTree
	wholeOut, filteredOut bool
}

// buildOpenState is what the user left a node of the tree as; dependencies marks a
// dependencies node, which opening every node leaves as it was.
type buildOpenState struct {
	open, dependencies bool
}

// buildOpenKey names the open state of a group (key "") or of one of its nodes by the node's
// key, which Core keeps across reloads and filters.
func buildOpenKey(instanceID, key string) string { return instanceID + "\x00" + key }

// buildGroupOpen says whether the group of the instance at index shows its tree: as the user
// left it, else open for the selected instance only.
func (p *project) buildGroupOpen(index int) bool {
	if state, ok := p.panels.buildOpen[buildOpenKey(p.build.instances[index].ID, "")]; ok {
		return state.open
	}
	return index == p.build.selected
}

// buildNodeOpen says whether a node of an instance's tree shows its children: as the user left
// it; else, after the user opened or closed every node, as that left them, but a dependencies
// node stays closed; else open for a project and closed for anything else, as IntelliJ shows a
// build tool's projects with their lifecycle and plugins closed.
func (p *project) buildNodeOpen(instanceID string, node *core.BuildTreeNode) bool {
	if state, ok := p.panels.buildOpen[buildOpenKey(instanceID, node.Key)]; ok {
		return state.open
	}
	if node.Kind == core.BuildTreeDependencies {
		return false
	}
	if open, ok := p.panels.buildFold[instanceID]; ok {
		return open
	}
	return node.Kind == core.BuildTreeProject
}

// setBuildOpen stores the open state of a group or a node.
func (p *project) setBuildOpen(key string, state buildOpenState) {
	if p.panels.buildOpen == nil {
		p.panels.buildOpen = map[string]buildOpenState{}
	}
	p.panels.buildOpen[key] = state
}

// setBuildGroupOpen stores whether the group of the instance at index shows its tree.
func (p *project) setBuildGroupOpen(index int, open bool) {
	p.setBuildOpen(buildOpenKey(p.build.instances[index].ID, ""), buildOpenState{open: open})
}

// setAllBuildGroups opens or closes every group and every node in them. It forgets what the
// user opened and closed inside the groups and stores the fold for each instance instead, so
// it costs as many steps as the user made, not as many as the trees hold. Opening keeps the
// dependencies nodes as they were, since each opened one runs the build tool.
func (p *project) setAllBuildGroups(open bool) {
	if p.panels.buildFold == nil {
		p.panels.buildFold = map[string]bool{}
	}
	for key, state := range p.panels.buildOpen {
		if _, node, _ := strings.Cut(key, "\x00"); node != "" && !(open && state.dependencies) {
			delete(p.panels.buildOpen, key)
		}
	}
	for index := range p.build.instances {
		p.panels.buildFold[p.build.instances[index].ID] = open
		p.setBuildGroupOpen(index, open)
	}
}

// chooseBuildInstance makes the instance at index the one the window acts on, before an
// action on one of its rows. The group of the instance selected before stays as it showed: it
// was open by default only for being selected.
func (a *App) chooseBuildInstance(p *project, index int) {
	b := &p.build
	if index == b.selected || index < 0 || index >= len(b.instances) {
		return
	}
	if previous := b.selected; previous >= 0 && previous < len(b.instances) {
		p.setBuildGroupOpen(previous, p.buildGroupOpen(previous))
	}
	p.setBuildGroupOpen(index, true)
	a.selectBuildInstance(p, index)
}

// loadOpenBuildModels starts the model loads of the open groups, at most buildModelLoadsAtOnce
// together. A model that failed or whose load the user stopped is not tried again by itself:
// the group shows the error and the user reloads it. The view calls it on every frame; a model that loads or is loaded asks
// for nothing.
func (a *App) loadOpenBuildModels(p *project) {
	b := &p.build
	loading := 0
	for index := range b.instances {
		if b.instances[index].modelLoading {
			loading++
		}
	}
	for index := range b.instances {
		if loading >= buildModelLoadsAtOnce {
			return
		}
		instance := &b.instances[index]
		if instance.modelLoaded || instance.modelLoading || instance.modelError != "" || !p.buildGroupOpen(index) {
			continue
		}
		a.loadBuildModel(p, index)
		if instance.modelLoading {
			loading++
		}
	}
}

// buildTreeOf is the tree of the instance at index for query, already trimmed and lower case,
// and starts its layout when the model, the filter or the language changed since the tree
// shown was laid out. Only one layout of each kind is out at a time: the one that ends starts
// the next when the tree it brought is already stale, so fast typing lays out only the
// queries the window still shows. The result is nil while the first layout is out and the
// model is not loaded; a filtered tree for an older query stands in for the current one.
func (a *App) buildTreeOf(p *project, index int, query string) *buildTree {
	instance := &p.build.instances[index]
	if !instance.modelLoaded {
		return nil
	}
	shown, out := instance.trees.whole, &instance.trees.wholeOut
	if query != "" {
		shown, out = instance.trees.filtered, &instance.trees.filteredOut
	}
	language := a.language()
	current := shown != nil && shown.version == instance.modelVersion &&
		shown.optionFingerprint == instance.OptionFingerprint &&
		shown.query == query && shown.language == language
	if !current && !*out {
		*out = true
		a.layOutBuildTree(p, instance, query, language)
	}
	return shown
}

// layOutBuildTree asks Core for the tree of instance's model for query off the window thread.
// The model's slices are never changed in place, only replaced, so the goroutine reads them as
// they were when the layout started.
func (a *App) layOutBuildTree(p *project, instance *buildInstance, query string, language i18n.Language) {
	kernel := a.kernel
	id, generation := instance.ID, p.build.generation
	manifest, buildSystemID, version, optionFingerprint := instance.Manifest, instance.BuildSystemID, instance.modelVersion, instance.OptionFingerprint
	options := make(map[string]json.RawMessage, len(instance.Options))
	for key, value := range instance.Options {
		options[key] = slices.Clone(value)
	}
	model := core.BuildModelTreeInput{
		Projects:              instance.Model.Projects,
		Targets:               instance.Model.Targets,
		Tasks:                 instance.Model.Tasks,
		OptionValues:          instance.Model.OptionValues,
		OptionDefaults:        instance.Model.OptionDefaults,
		OptionExcludePrefixes: instance.Model.OptionExcludePrefixes,
		OptionSelection:       instance.Model.OptionSelection,
	}
	headings := buildGroupHeadings(language)
	a.background(p, buildTreeTimeout, func(ctx context.Context) func(*App) {
		tree := &buildTree{version: version, optionFingerprint: optionFingerprint, query: query, language: language}
		laid, err := kernel.BuildModelTree(ctx, manifest, buildSystemID, core.BuildModelTreeRequest{
			Model: model, Options: options, Query: query, GroupHeadings: headings,
		})
		if err != nil {
			a.backgroundFailedIn(ctx, "build_tree", err)
			tree.failed = err.Error()
		} else {
			tree.tree = laid
			tree.targets = make(map[string]int, len(model.Targets))
			for at := range model.Targets {
				if _, seen := tree.targets[model.Targets[at].ID]; !seen {
					tree.targets[model.Targets[at].ID] = at
				}
			}
		}
		return func(a *App) { a.finishBuildTree(p, id, generation, tree) }
	})
}

// finishBuildTree stores a laid out tree in its instance, unless the instances were detected
// again since the layout started or the model changed under it. A stale tree is dropped and
// the next frame lays out the current one.
func (a *App) finishBuildTree(p *project, id string, generation uint64, tree *buildTree) {
	if a.project != p || p.build.generation != generation {
		return
	}
	instance := p.buildInstanceByID(id)
	if instance == nil {
		return
	}
	trees := &instance.trees
	if tree.query == "" {
		trees.wholeOut = false
	} else {
		trees.filteredOut = false
	}
	if tree.version != instance.modelVersion || tree.optionFingerprint != instance.OptionFingerprint {
		return
	}
	if tree.query == "" {
		trees.whole = tree
	} else {
		trees.filtered = tree
	}
}

// targetOf is the model target a target node of tree stands for, nil when the model no longer
// has it.
func (instance *buildInstance) targetOf(tree *buildTree, id string) *core.BuildTarget {
	at, ok := tree.targets[id]
	if !ok || at >= len(instance.Model.Targets) || instance.Model.Targets[at].ID != id {
		return nil
	}
	return &instance.Model.Targets[at]
}

// buildSystemName is the name of an instance's build system, without its root.
func buildSystemName(instance *buildInstance) string {
	if name := instance.System.DisplayName; name != "" {
		return name
	}
	return instance.BuildSystemID
}

// buildRootDetail is the root an instance shows beside its name, empty for the workspace's.
func buildRootDetail(instance *buildInstance) string {
	if root := instance.Root; root != "" && root != "." {
		return root
	}
	return ""
}

// buildMatches says whether the filter query, already lower case, is in the label or the detail.
func buildMatches(query, label, detail string) bool {
	return strings.Contains(strings.ToLower(label), query) || strings.Contains(strings.ToLower(detail), query)
}

// buildFilterQuery is the tree's filter as it is matched: trimmed and lower case.
func (p *project) buildFilterQuery() string {
	return strings.ToLower(strings.TrimSpace(p.panels.buildFilter))
}

// buildTreeRows lists the rows of the tree in the order it shows them, into a buffer the
// window reuses. Without a filter every group shows as the user left it. With one, a group
// whose name or root matches shows as without a filter; another shows what Core kept of its
// tree, every node on the way to a match open and each match as the user left it, and is
// left out when nothing in it matches. The filter reads the models already loaded and never
// starts a load: it narrows what the tree holds, it does not ask the build tools. pending says
// a group was left out only because its first filtered tree is still being laid out, so an
// empty tree is not yet known to match nothing.
func (a *App) buildTreeRows(p *project) (rows []buildRow, pending bool) {
	b := &p.build
	query := p.buildFilterQuery()
	rows = p.panels.buildRows[:0]
	for index := range b.instances {
		instance := &b.instances[index]
		group := buildRow{
			kind: buildRowGroup, instance: index, label: buildSystemName(instance), detail: buildRootDetail(instance),
			selected: index == b.selected, loading: instance.modelLoading, warning: instance.modelError != "" && !instance.modelStopped,
		}
		if query == "" || buildMatches(query, group.label, group.detail) {
			group.open = p.buildGroupOpen(index)
			// A closed group is laid out too once its model is loaded, so its row names the
			// project it stands for whether it is open or not. The layout only reads the model.
			tree := a.buildTreeOf(p, index, "")
			group.node = rootProjectOf(tree)
			rows = append(rows, group)
			if group.open {
				rows = a.appendBuildTree(rows, p, index, tree, false)
			}
			continue
		}
		tree := a.buildTreeOf(p, index, query)
		if tree == nil || tree.failed != "" {
			pending = pending || tree == nil && instance.trees.filteredOut
			continue
		}
		group.node = rootProjectOf(tree)
		// A match on the project the group stands for keeps the whole tree, as the user left it.
		filtering := group.node == nil || !group.node.Matched
		group.open, group.fixed = true, true
		rows = append(rows, group)
		start := len(rows)
		rows = a.appendBuildTree(rows, p, index, tree, filtering)
		if len(rows) == start && filtering {
			rows = rows[:start-1]
		}
	}
	p.panels.buildRows = rows
	return rows, pending
}

// rootProjectOf is the project a group stands for, the only root project of its model.
func rootProjectOf(tree *buildTree) *core.BuildTreeNode {
	if tree == nil {
		return nil
	}
	return tree.tree.Project
}

// appendBuildTree appends the rows of the tree of the instance at index under its group:
// what the model or the tree's layout are doing when they are not ready, else the open nodes.
// filtering says the tree is what a filter kept; it then shows no line for what is missing.
func (a *App) appendBuildTree(rows []buildRow, p *project, index int, tree *buildTree, filtering bool) []buildRow {
	t := a.text.Build
	instance := &p.build.instances[index]
	note := func(label string) buildRow {
		return buildRow{kind: buildRowEmpty, instance: index, level: 1, label: label}
	}
	// A click on a line about the model shows its load's log in the Run window.
	var session *runEntry
	if !filtering && !instance.modelLoaded {
		session = p.buildSyncSession(instance.ID)
	}
	switch {
	case filtering:
	case instance.modelStopped:
		row := note(instance.modelError)
		row.model = true
		if session != nil {
			row.sync = session.id
		}
		return append(rows, row)
	case instance.modelError != "":
		// The row has one line; the tool's own explanation that follows is its tooltip.
		first, _, more := strings.Cut(instance.modelError, "\n")
		row := note(t.ModelFailed(first))
		row.warning, row.model = true, true
		if more {
			row.tooltip = t.ModelFailed(instance.modelError)
		}
		if session != nil {
			row.sync = session.id
		}
		return append(rows, row)
	case !instance.modelLoaded || tree == nil:
		row := note(t.LoadingModel)
		row.loading = true
		// While the model loads, the row tells what the load does now, as its last line says.
		if session != nil && session.running {
			row.detail, row.sync = session.sync.latest, session.id
			row.tooltip = i18n.Shared(a.language(), "desktop.build.showSyncOutput")
		}
		return append(rows, row)
	case tree.failed != "":
		first, _, _ := strings.Cut(tree.failed, "\n")
		row := note(i18n.SharedFormat(a.language(), "desktop.build.treeFailed", map[string]string{"error": first}))
		row.warning, row.tooltip = true, tree.failed
		return append(rows, row)
	case len(tree.tree.Nodes) == 0:
		return append(rows, note(t.NoTasks))
	}
	if tree == nil {
		return rows
	}
	rows = a.appendBuildNodes(rows, p, index, tree, tree.tree.Nodes, 1, filtering, "")
	if tree.tree.Truncated && !filtering {
		row := note(i18n.Shared(a.language(), "desktop.build.treeTruncated"))
		row.warning = true
		rows = append(rows, row)
	}
	return rows
}

// appendBuildNodes appends nodes at level and, under each open one, its children: the nodes
// Core nested in it, or the dependencies or discovered tests the host loads for it. While
// filtering, a node Core kept for a match below it is open and stays so, and a match shows as
// the user left it with all it holds; the discovered tests node shows only the tests that
// match, and is left out when none does.
func (a *App) appendBuildNodes(rows []buildRow, p *project, index int, tree *buildTree, nodes []core.BuildTreeNode, level int, filtering bool, optionTitle string) []buildRow {
	b, t, language := &p.build, a.text.Build, a.language()
	instance := &b.instances[index]
	selected := index == b.selected
	query := ""
	if filtering {
		query = p.buildFilterQuery()
	}
	for at := range nodes {
		node := &nodes[at]
		row := buildRow{instance: index, level: level, node: node, label: node.Label, detail: node.Detail, tooltip: node.Tooltip}
		fixed := filtering && !node.Matched
		var tests []buildRow
		switch node.Kind {
		case core.BuildTreeProject:
			row.kind = buildRowProject
			row.selected = selected && b.projectID == node.ProjectID && b.targetID == "" && b.taskID == ""
		case core.BuildTreeTarget:
			row.kind, row.target = buildRowTarget, instance.targetOf(tree, node.TargetID)
			row.selected = selected && b.targetID == node.TargetID && b.taskID == ""
		case core.BuildTreeTask:
			row.kind = buildRowTask
			row.selected = selected && b.taskID == node.TaskID && b.projectID == node.ProjectID && b.targetID == node.TargetID
		case core.BuildTreeFolder, core.BuildTreeOption:
			// Core names the folder: by its category heading, option display name, or group heading.
			row.kind = buildRowFolder
		case core.BuildTreeOptionChoice:
			row.kind, row.optionTitle = buildRowOptionChoice, optionTitle
			if node.DefaultActive {
				row.detail = i18n.Shared(language, "desktop.build.optionChoiceDefault")
			}
		case core.BuildTreeTargets:
			row.kind, row.label = buildRowFolder, t.Targets
		case core.BuildTreeDependencies:
			row.kind, row.label = buildRowFolder, i18n.Shared(language, "native.dependencies")
		case core.BuildTreeTests:
			row.kind, row.label = buildRowFolder, i18n.Shared(language, "native.discoveredTests")
			if fixed {
				// Core keeps the tests node for the host to filter, as it alone has the tests.
				if tests = a.buildTestRows(p, index, "", query, level+1); len(tests) == 0 {
					continue
				}
			}
		default:
			continue
		}
		row.branch = len(node.Children) != 0 || node.Kind == core.BuildTreeDependencies || node.Kind == core.BuildTreeTests
		row.fixed = fixed && row.branch
		row.open = row.branch && (row.fixed || p.buildNodeOpen(instance.ID, node))
		rows = append(rows, row)
		if !row.open {
			continue
		}
		switch node.Kind {
		case core.BuildTreeDependencies:
			rows = a.appendBuildDependencyRows(rows, p, index, node.ProjectID, level+1)
		case core.BuildTreeTests:
			if tests == nil {
				tests = a.buildTestRows(p, index, "", "", level+1)
			}
			rows = append(rows, tests...)
		default:
			childOption := optionTitle
			if node.Kind == core.BuildTreeOption {
				childOption = node.Label
			}
			rows = a.appendBuildNodes(rows, p, index, tree, node.Children, level+1, fixed, childOption)
		}
	}
	return rows
}

// toggleBuildTreeOptionChoice flips one choice of a tree-presented multi-select option on the
// instance at index, writes the updated local option document through Core, and reloads the
// build systems so the model, tasks, dependencies and run configurations pick up the change.
func (a *App) toggleBuildTreeOptionChoice(p *project, index int, optionID, choiceValue string) {
	b := &p.build
	if b.optionSaving || b.loading || b.operation != nil || index < 0 || index >= len(b.instances) {
		return
	}
	instance := &b.instances[index]
	if !instance.modelLoaded || instance.modelLoading || optionID == "" || choiceValue == "" {
		return
	}
	docs, err := a.readBuildOptionDocuments(context.Background(), p.root)
	if err != nil {
		a.notifyError(a.launchFailureText(err))
		return
	}
	b.optionSaving = true
	captured := *instance
	kernel, root := a.kernel, p.root
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		fields, err := resolveInstanceOptionFields(ctx, kernel, captured, nil)
		if err != nil {
			return func(a *App) {
				p.build.optionSaving = false
				a.notifyError(a.launchFailureText(err))
			}
		}
		var next []string
		found := false
		for _, field := range fields {
			if field.id != optionID {
				continue
			}
			for at, choice := range field.choices {
				checked := at < len(field.picks) && field.picks[at]
				if choice.value == choiceValue {
					checked = !checked
					found = true
				}
				if checked {
					next = append(next, choice.value)
				}
			}
			break
		}
		if !found {
			return func(a *App) { p.build.optionSaving = false }
		}
		if next == nil {
			next = []string{}
		}
		edit, err := kernel.EditStoredBuildOption(ctx, captured.Manifest, captured.BuildSystemID, core.BuildOptionEditRequest{
			Document:             docs.team,
			Local:                docs.local,
			Root:                 captured.Root,
			OptionID:             optionID,
			SelectedChoices:      next,
			HasSelectedChoices:   true,
			ModelValues:          captured.Model.OptionValues,
			ModelDefaults:        captured.Model.OptionDefaults,
			ModelExcludePrefixes: captured.Model.OptionExcludePrefixes,
			ModelSelection:       captured.Model.OptionSelection,
		})
		if err != nil {
			return func(a *App) {
				p.build.optionSaving = false
				a.notifyError(a.launchFailureText(err))
			}
		}
		return func(a *App) {
			p.build.optionSaving = false
			if a.project != p {
				return
			}
			if err := a.storeBuildLocalOptions(root, edit.Local); err != nil {
				a.notifyError(a.launchFailureText(err))
				return
			}
			p.reloadBuildDependencies()
			p.revokeBuildTests(captured.ID)
			a.requestBuildReload(p)
		}
	})
}

// reloadBuildSystems detects the workspace's build systems again: the instances, their models,
// trees, dependency trees and discovered tests are dropped and found anew. What the user
// opened and closed is kept by instance and node, so an instance found again shows as before.
func (a *App) reloadBuildSystems(p *project) {
	b := &p.build
	p.reloadBuildDependencies()
	p.revokeAllBuildTests()
	b.generation++
	b.loading = false
	b.instances = nil
	a.publishWorkspaceBuildOptions(nil)
	b.loaded = false
	b.selected = 0
	a.loadBuildSystems(p)
}

// buildTargetAction is what the Run button of a target row starts: one run the provider
// declares (runID), whose debug says it names a debug adapter too, or one command Run entry
// Core derived (entryID).
type buildTargetAction struct {
	runID, entryID, name string
	debug                bool
}

// buildPrimaryAction is the first of a target's runs, as its context menu lists them: the
// provider's runs that apply to it, then the command entries. ok is false when it has none.
func buildPrimaryAction(instance *buildInstance, target *core.BuildTarget) (buildTargetAction, bool) {
	if target == nil {
		return buildTargetAction{}, false
	}
	for _, run := range instance.System.Runs {
		if buildRunApplies(run, *target) {
			return buildTargetAction{runID: run.ID, name: run.ActionName(target.Name), debug: run.Debuggable()}, true
		}
	}
	if entries := buildTargetRunEntries(instance, target.ID); len(entries) != 0 {
		return buildTargetAction{entryID: entries[0].ID, name: entries[0].Name}, true
	}
	return buildTargetAction{}, false
}

// runBuildTargetAction runs action on the target of the selected instance.
func (a *App) runBuildTargetAction(p *project, targetID string, action buildTargetAction) {
	if action.entryID != "" {
		a.runBuildEntry(p, action.entryID)
		return
	}
	a.runBuildTarget(p, targetID, action.runID)
}

// buildChosenAction is what the window's Run button starts for the selection of the selected
// instance: the chosen task, else the first run of the chosen target. ok is false when nothing
// runnable is chosen.
func (a *App) buildChosenAction(p *project) (label string, run func(), ok bool) {
	b, t := &p.build, a.text.Build
	instance := p.selectedBuildInstance()
	if instance == nil || !instance.modelLoaded {
		return "", nil, false
	}
	if b.taskID != "" {
		return t.RunSelected, func() { a.runSelectedBuildTask(p) }, true
	}
	if b.targetID == "" {
		return "", nil, false
	}
	target, found := buildTargetByID(instance.Model, b.targetID)
	if !found {
		return "", nil, false
	}
	action, found := buildPrimaryAction(instance, &target)
	if !found {
		return "", nil, false
	}
	targetID := target.ID
	return t.RunTarget(action.name), func() { a.runBuildTargetAction(p, targetID, action) }, true
}

// buildSystemFamily is the badge color of a build system: one of the symbol families but the
// grey of plain values, chosen by the system's identity, so the same tool always has the same
// color and two tools side by side most often differ.
func buildSystemFamily(buildSystemID string) symbolFamily {
	h := fnv.New32a()
	_, _ = h.Write([]byte(buildSystemID))
	return symbolFamily(1 + h.Sum32()%uint32(familyModule))
}
