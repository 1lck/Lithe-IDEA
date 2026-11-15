//go:build !dev

package buildinfo

import "testing"

func TestDevelopmentIsFalseWithoutDevTag(t *testing.T) {
	if Development {
		t.Fatal("Development = true without the dev build tag, want false")
	}
}
