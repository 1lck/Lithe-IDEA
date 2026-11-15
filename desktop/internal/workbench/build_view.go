package workbench

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// buildRowHeight is the height of a row of the build tree and of the Run window's tree.
const buildRowHeight = 24

// buildRowKind says what a row of the build tree is.
type buildRowKind uint8

const (
	buildRowGroup buildRowKind = iota
	buildRowSection
	buildRowEmpty
	buildRowProject
	buildRowTarget
	buildRowTask
	buildRowDependency
	buildRowTest
)

// buildRow is one row of the build tree (build_tree.go): a build system's group, a section
// of it, a note that a section is empty or still loading, or something to choose or run.
type buildRow struct {
	kind     buildRowKind
	label    string
	detail   string
	selected bool
	// tooltip is what the row shows while the pointer rests on it: the full name of a target
	// whose label is its path alone (buildTargetLabel); empty for none.
	tooltip string
	// instance is the index of the build system the row belongs to, level its indentation in
	// the tree, and section the section a section row heads.
	instance int
	level    int
	section  string
	// count is what a section row shows beside its name, -1 for not known yet; open says a
	// group or a section shows its rows, and fixed that a filter keeps it open.
	count       int
	open, fixed bool
	// warning marks a row that tells of a failure, loading one of a model still loading.
	warning, loading bool
	// id is the project, target or task the row chooses; project is the project a
	// target belongs to.
	id, project string
	target      *core.BuildTarget
	// path and leaf place a dependency row in its tree (build_dependencies.go); dependencies
	// marks the line that stands for a tree still loading, failed or empty.
	path         string
	leaf         bool
	dependencies bool
	// tests marks a line of the Discovered Tests section that is not a test, and discover the
	// one that starts discovery; test is the discovered test a row runs (build_tests.go).
	tests    bool
	discover bool
	test     *core.BuildDiscoveredTest
}

// declaredTasks are the tasks the manifest names itself, command and provider alike; a fromModel
// template is listed through the model tasks it stands for.
func declaredTasks(instance *buildInstance) []pluginservice.BuildTaskDeclaration {
	if instance == nil {
		return nil
	}
	tasks := make([]pluginservice.BuildTaskDeclaration, 0, len(instance.System.Tasks))
	for _, task := range instance.System.Tasks {
		if !task.FromModel {
			tasks = append(tasks, task)
		}
	}
	return tasks
}

// buildTaskDetail is what a task row shows beside its name: its category path, else its group.
func buildTaskDetail(task *pluginservice.BuildTaskDeclaration) string {
	if len(task.Category) != 0 {
		return strings.Join(task.Category, " / ")
	}
	return task.Group
}

func buildTaskName(task *pluginservice.BuildTaskDeclaration) string {
	if task.DisplayName != "" {
		return task.DisplayName
	}
	return task.ID
}

func buildRunApplies(run pluginservice.BuildRunDeclaration, target core.BuildTarget) bool {
	if len(run.Tags) == 0 {
		return true
	}
	for _, tag := range run.Tags {
		for _, targetTag := range target.Tags {
			if tag == targetTag {
				return true
			}
		}
	}
	return false
}
