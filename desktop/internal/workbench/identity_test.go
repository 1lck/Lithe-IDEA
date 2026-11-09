package workbench

import (
	"hash/fnv"
	"testing"

	"github.com/vivaui/viva/gfx"
)

func TestIdentityInitials(t *testing.T) {
	cases := []struct {
		name, want string
	}{
		// Two words give one letter each.
		{"lithe-idea", "LI"},
		{"我的 项目", "我项"},
		{"hello_world", "HW"},
		{"  spaced   out  ", "SO"},
		// Only the first two words count.
		{"one two three", "OT"},
		// A single word gives one letter, in upper case.
		{"motty", "M"},
		{"éclair", "É"},
		{"éclair pie", "ÉP"},
		// A digit starts a word like a letter does.
		{"2fa-app", "2A"},
		// A combining mark stays with its letter and does not start another word.
		{"e\u0301cole", "E"},
		// Nothing to take a letter from shows the fallback.
		{"---", "LI"},
		{"._ ", "LI"},
		{"", "LI"},
	}
	for _, c := range cases {
		if got := identityInitials(c.name); got != c.want {
			t.Errorf("identityInitials(%q) = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestIdentityColorIndexIsStableAndInRange(t *testing.T) {
	paths := []string{
		"", "/", "/Users/ann/Dev/lithe", "/Users/ann/Dev/lithe/", `C:\Users\ann\lithe`,
		"/Users/ann/项目", "/tmp/a", "/tmp/b",
	}
	for _, path := range paths {
		got := identityColorIndex(path)
		if got < 0 || got >= len(identityGradients) {
			t.Errorf("identityColorIndex(%q) = %d, outside 0..%d", path, got, len(identityGradients)-1)
		}
		if again := identityColorIndex(path); again != got {
			t.Errorf("identityColorIndex(%q) = %d, then %d", path, got, again)
		}
	}
}

// TestIdentityColorIndexIsFNV1a pins the hash, because the macOS client computes the same
// one and a project must have the same color in both.
func TestIdentityColorIndexIsFNV1a(t *testing.T) {
	for _, path := range []string{"", "a", "/Users/ann/Dev/lithe", "/Users/ann/项目"} {
		hasher := fnv.New64a()
		hasher.Write([]byte(path))
		want := int(hasher.Sum64() % uint64(len(identityGradients)))
		if got := identityColorIndex(path); got != want {
			t.Errorf("identityColorIndex(%q) = %d, want %d from hash/fnv", path, got, want)
		}
	}
}

func TestIdentityOf(t *testing.T) {
	path := "/Users/ann/Dev/lithe-idea"
	got := identityOf(path, "lithe-idea")
	gradient := identityGradients[identityColorIndex(path)]
	if got.initials != "LI" {
		t.Errorf("initials = %q, want LI", got.initials)
	}
	if got.start != gfx.RGB24(gradient[0]) || got.end != gfx.RGB24(gradient[1]) {
		t.Errorf("gradient = %v to %v, want the entry %v of the palette", got.start, got.end, gradient)
	}
	if again := identityOf(path, "lithe-idea"); again != got {
		t.Errorf("identityOf is not stable: %v then %v", got, again)
	}
}

func TestIdentityFontFitsTheBadge(t *testing.T) {
	cases := []struct {
		initials string
		side     float32
		size     float32
		mono     bool
	}{
		// Latin initials keep the macOS proportion, 13 on 20, and stay monospaced.
		{"LI", 20, 13, true},
		{"M", 28, 18, true},
		{"LI", 32, 20, true},
		// One Chinese character fits at the full size; two do not and are made smaller.
		{"我", 20, 13, false},
		{"我项", 20, 9, false},
		{"我项", 32, 14, false},
	}
	for _, c := range cases {
		size, mono := identityFont(c.initials, c.side)
		if size != c.size || mono != c.mono {
			t.Errorf("identityFont(%q, %v) = %v, %v; want %v, %v", c.initials, c.side, size, mono, c.size, c.mono)
		}
	}
}
