package ai

import "testing"

func TestStagedChangeKindUsesTheIndexSide(t *testing.T) {
	for status, want := range map[string]string{"A ": "added", "M ": "modified", "MM": "modified", "D ": "deleted", "R ": "renamed", "C ": "copied", "UU": "unmerged", "": "modified"} {
		if got := StagedChangeKind(status); got != want {
			t.Errorf("%q = %q, want %q", status, got, want)
		}
	}
}
