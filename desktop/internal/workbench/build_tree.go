package workbench

import (
	"hash/fnv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// The Build tool window on the right stripe: every build system the workspace uses, as one
// tree. A workspace can hold many of them (a nested checkout per module, one build tool beside
// another), so they are not tabs to switch between but groups the user opens and closes, each
// with its projects, dependencies, targets, tasks and discovered tests as sections.
//
// The window's actions act on one instance, the selected one (build.go): a click on a row of
// another group selects that group's instance first. The selected instance's group is open
// until the user closes it, and only its rows show a selection and the project scope; the
// other groups show what their model holds.
//
// A group's model is loaded when the group is open, a few at a time, so a workspace of many
// build systems does not start every build tool at once. The dependencies section starts
// closed: its tree is a command of the build tool, run only once the user asks to see it.

// The sections of one build system's group, by the key their open state is stored under.
const (
	buildSectionProjects     = "projects"
	buildSectionDependencies = "dependencies"
	buildSectionTargets      = "targets"
	buildSectionTasks        = "tasks"
	buildSectionTests        = "tests"
)

// buildModelLoadsAtOnce bounds the models loaded together for the open groups; the next one
// starts when one of them ends.
const buildModelLoadsAtOnce = 4

// buildOpenKey names the open state of a group (section "") or of one of its sections.
func buildOpenKey(instanceID, section string) string { return instanceID + "\x00" + section }

// buildGroupOpen says whether the group of the instance at index shows its sections: as the
// user left it, else open for the selected instance only.
func (p *project) buildGroupOpen(index int) bool {
	if open, ok := p.panels.buildOpen[buildOpenKey(p.build.instances[index].ID, "")]; ok {
		return open
	}
	return index == p.build.selected
}

// buildSectionOpen says whether a section of a group shows its rows: as the user left it, else
// open, except the dependencies, whose tree costs a run of the build tool.
func (p *project) buildSectionOpen(instanceID, section string) bool {
	if open, ok := p.panels.buildOpen[buildOpenKey(instanceID, section)]; ok {
		return open
	}
	return section != buildSectionDependencies
}

// setBuildOpen stores the open state of a group or a section.
func (p *project) setBuildOpen(key string, open bool) {
	if p.panels.buildOpen == nil {
		p.panels.buildOpen = map[string]bool{}
	}
	p.panels.buildOpen[key] = open
}

// setAllBuildGroups opens or closes every group. Opening also opens the sections that cost
// nothing to show; the dependencies stay as they were.
func (p *project) setAllBuildGroups(open bool) {
	for index := range p.build.instances {
		id := p.build.instances[index].ID
		p.setBuildOpen(buildOpenKey(id, ""), open)
		if open {
			for _, section := range []string{buildSectionProjects, buildSectionTargets, buildSectionTasks, buildSectionTests} {
				p.setBuildOpen(buildOpenKey(id, section), true)
			}
		}
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
		p.setBuildOpen(buildOpenKey(b.instances[previous].ID, ""), p.buildGroupOpen(previous))
	}
	p.setBuildOpen(buildOpenKey(b.instances[index].ID, ""), true)
	a.selectBuildInstance(p, index)
}

// loadOpenBuildModels starts the model loads of the open groups, at most buildModelLoadsAtOnce
// together. A model that failed is not tried again by itself: the group shows the error and
// the user reloads it. The view calls it on every frame; a model that loads or is loaded asks
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

// buildTreeRows lists the rows of the tree in the order it shows them. Without a filter every
// group shows as the user left it. With one, a group whose name or root matches shows as
// without a filter; another shows only its projects, targets, tasks and tests that match, all
// open, and is left out when none does. The filter reads the models already loaded and never
// starts a load: it narrows what the tree holds, it does not ask the build tools.
func (a *App) buildTreeRows(p *project) []buildRow {
	b := &p.build
	query := p.buildFilterQuery()
	var rows []buildRow
	for index := range b.instances {
		instance := &b.instances[index]
		group := buildRow{
			kind: buildRowGroup, instance: index, label: buildSystemName(instance), detail: buildRootDetail(instance),
			selected: index == b.selected, loading: instance.modelLoading, warning: instance.modelError != "",
		}
		if query == "" || buildMatches(query, group.label, group.detail) {
			group.open = p.buildGroupOpen(index)
			rows = append(rows, group)
			if group.open {
				rows = a.appendBuildGroup(rows, p, index, "")
			}
			continue
		}
		matched := a.appendBuildGroup(nil, p, index, query)
		if len(matched) == 0 {
			continue
		}
		group.open, group.fixed = true, true
		rows = append(rows, group)
		rows = append(rows, matched...)
	}
	return rows
}

// appendBuildGroup appends the sections of the instance at index; with a query, only the rows
// that match it, under the sections that hold any.
func (a *App) appendBuildGroup(rows []buildRow, p *project, index int, query string) []buildRow {
	b, t := &p.build, a.text.Build
	instance := &b.instances[index]
	filtering := query != ""
	if !instance.modelLoaded {
		switch {
		case filtering:
		case instance.modelError != "":
			rows = append(rows, buildRow{kind: buildRowEmpty, instance: index, level: 1, label: t.ModelFailed(instance.modelError), warning: true})
		default:
			rows = append(rows, buildRow{kind: buildRowEmpty, instance: index, level: 1, label: t.LoadingModel, loading: true})
		}
		return rows
	}
	selected := index == b.selected
	// The project scope is the selected instance's, and a search looks past it.
	scope := ""
	if selected && !filtering {
		scope = b.projectID
	}
	keep := func(label, detail string) bool { return !filtering || buildMatches(query, label, detail) }
	// add appends one section and, when it is open, its rows. Without a filter count is what
	// the heading shows, -1 for not known yet, and items is asked for only when the section is
	// open, so a closed section loads nothing; with one, the section shows only its matches.
	add := func(section, label string, count int, items func() []buildRow) {
		if filtering {
			list := items()
			if len(list) == 0 {
				return
			}
			rows = append(rows, buildRow{kind: buildRowSection, instance: index, level: 1, section: section, label: label, count: len(list), open: true, fixed: true})
			rows = append(rows, list...)
			return
		}
		open := p.buildSectionOpen(instance.ID, section)
		rows = append(rows, buildRow{kind: buildRowSection, instance: index, level: 1, section: section, label: label, count: count, open: open})
		if open {
			rows = append(rows, items()...)
		}
	}
	model := &instance.Model

	projects := make([]buildRow, 0, len(model.Projects))
	for _, project := range model.Projects {
		name := project.DisplayName
		if name == "" {
			name = project.Name
		}
		if keep(name, project.Path) {
			// The project at the build root says nothing more with a path of ".".
			detail := project.Path
			if detail == "." {
				detail = ""
			}
			projects = append(projects, buildRow{kind: buildRowProject, instance: index, level: 2, label: name, detail: detail, id: project.ID, selected: selected && b.projectID == project.ID})
		}
	}
	if len(model.Projects) != 0 {
		add(buildSectionProjects, t.Projects, len(projects), func() []buildRow { return projects })
	}

	if projectID, ok := buildDependencyProject(instance, scope); ok && !filtering {
		count := -1
		if deps := b.dependencies[buildDependencyKey(instance.ID, projectID)]; deps != nil && !deps.loading && deps.failed == "" {
			count = len(deps.tree.Dependencies)
		}
		add(buildSectionDependencies, i18n.Shared(a.language(), "native.dependencies"), count, func() []buildRow {
			return a.buildDependencyRows(p, index, projectID, 2)
		})
	}

	var targets []buildRow
	for at := range model.Targets {
		target := &model.Targets[at]
		if scope != "" && target.ProjectID != scope || !keep(target.Name, target.Path) {
			continue
		}
		targets = append(targets, buildRow{
			kind: buildRowTarget, instance: index, level: 2, label: target.Name, detail: target.Path,
			id: target.ID, project: target.ProjectID, selected: selected && b.targetID == target.ID, target: target,
		})
	}
	if len(targets) != 0 {
		add(buildSectionTargets, t.Targets, len(targets), func() []buildRow { return targets })
	}

	var tasks []buildRow
	for _, task := range declaredTasks(instance) {
		if name, detail := buildTaskName(&task), buildTaskDetail(&task); keep(name, detail) {
			tasks = append(tasks, buildRow{kind: buildRowTask, instance: index, level: 2, label: name, detail: detail, id: task.ID, selected: selected && b.taskID == task.ID})
		}
	}
	for _, task := range model.Tasks {
		name := task.DisplayName
		if name == "" {
			name = task.Name
		}
		if detail := strings.Join(task.Category, " / "); keep(name, detail) {
			tasks = append(tasks, buildRow{kind: buildRowTask, instance: index, level: 2, label: name, detail: detail, id: task.ID, selected: selected && b.taskID == task.ID})
		}
	}
	add(buildSectionTasks, t.Tasks, len(tasks), func() []buildRow {
		if len(tasks) == 0 && !filtering {
			return []buildRow{{kind: buildRowEmpty, instance: index, level: 2, label: t.NoTasks}}
		}
		return tasks
	})

	if instance.System.Test != nil && instance.System.Test.Discovery {
		count := -1
		if view := p.discoveredTestsView(instance); view.loaded && !view.loading {
			count = len(buildScopedTests(instance, view.tests, scope, ""))
		}
		add(buildSectionTests, i18n.Shared(a.language(), "native.discoveredTests"), count, func() []buildRow {
			return a.buildTestRows(p, index, scope, query, 2)
		})
	}
	return rows
}

// reloadBuildSystems detects the workspace's build systems again: the instances, their models,
// dependency trees and discovered tests are dropped and found anew. What the user opened and
// closed is kept by instance, so an instance found again shows as before.
func (a *App) reloadBuildSystems(p *project) {
	b := &p.build
	p.reloadBuildDependencies()
	p.revokeAllBuildTests()
	b.generation++
	b.loading = false
	b.instances = nil
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
	for _, run := range instance.System.Runs {
		if buildRunApplies(run, *target) {
			return buildTargetAction{runID: run.ID, name: run.Name, debug: run.DebugAdapter != ""}, true
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
