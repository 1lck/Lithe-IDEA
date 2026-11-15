//go:build dev

package buildinfo

import "testing"

func TestDevelopmentIsTrueWithDevTag(t *testing.T) {
	if !Development {
		t.Fatal("Development = false with the dev build tag, want true")
	}
}
