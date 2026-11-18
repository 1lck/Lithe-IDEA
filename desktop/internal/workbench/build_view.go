package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// buildRowHeight is the height of a row of the build tree and of the Run window's tree.
const buildRowHeight = 24

// buildRowKind says what a row of the build tree is.
type buildRowKind uint8

const (
	buildRowGroup buildRowKind = iota
	// buildRowFolder heads nodes it holds: a task folder, a tree-presented option, a project's
	// targets, dependencies or discovered tests.
	buildRowFolder
	buildRowEmpty
	buildRowProject
	buildRowTarget
	buildRowTask
	buildRowDependency
	buildRowTest
	buildRowOptionChoice
)

// buildRow is one row of the build tree (build_tree.go): a build system's group, a node of
// the tree Core laid out for it, a dependency or discovered test the host loads under one, or
// a note that something is empty, still loading or failed.
type buildRow struct {
	kind        buildRowKind
	label       string
	detail      string
	optionTitle string
	selected    bool
	// tooltip is what the row shows while the pointer rests on it: the full name of a target
	// whose label is its path alone, or a task's description; empty for none.
	tooltip string
	// instance is the index of the build system the row belongs to and level its indentation
	// in the tree.
	instance int
	level    int
	// node is the tree node a folder, project, target or task row shows; on a group row, the
	// project the group stands for, nil when its model has no single root project. Its IDs are
	// what the row chooses and runs.
	node *core.BuildTreeNode
	// branch says the row has children to show, open that it shows them, and fixed that a
	// filter keeps it open.
	branch, open, fixed bool
	// warning marks a row that tells of a failure, loading one of a model still loading, and
	// model the line that tells the model failed, whose menu loads it again.
	warning, loading, model bool
	// sync is the Run window session of the model load a model line tells of, which a click on
	// the line shows (build_sync.go); empty for none.
	sync string
	// id is the discovered test a test row runs; project is the project whose dependency
	// tree a dependency row belongs to.
	id, project string
	// target is the model target a target row stands for, nil when the model no longer has it.
	target *core.BuildTarget
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
