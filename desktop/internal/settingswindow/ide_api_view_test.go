package settingswindow

import (
	"slices"
	"sync"
	"testing"

	"github.com/vivaui/viva/gfx"
)

// fakeIDEAPI is the Core-backed side of the IDE Connection page: it records each remembered
// pair of grants and shows it in the next State.
type fakeIDEAPI struct {
	mu     sync.Mutex
	state  IDEAPIState
	grants [][2]bool
}

func (f *fakeIDEAPI) State() IDEAPIState {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.state
}

func (f *fakeIDEAPI) Allow(configure, execute bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.grants = append(f.grants, [2]bool{configure, execute})
	f.state.Configure, f.state.Execute = configure, execute
}

func (f *fakeIDEAPI) Enable(bool, bool)  {}
func (f *fakeIDEAPI) Disable()           {}
func (f *fakeIDEAPI) CopyConfiguration() {}

func (f *fakeIDEAPI) remembered() [][2]bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.grants)
}

// TestIDEAPIGrantSwitchesApplyWhenFlipped covers the IDE Connection page's two grants while
// the connection is off: opening the page writes nothing, and each click remembers the
// flipped grant with the other one kept.
func TestIDEAPIGrantSwitchesApplyWhenFlipped(t *testing.T) {
	loader := &fakeIDEAPI{state: IDEAPIState{HasProject: true}}
	w := newWindow(NewController(Options{IDEAPI: loader}), Values{})
	w.sess.page = pageIDEAPI
	d := openWindow(t, w)
	configure, execute := w.text.IDEAPI.AllowConfigure, w.text.IDEAPI.AllowExecute

	for _, label := range []string{configure, execute} {
		if hit := d.hit(label); hit.Role != gfx.RoleSwitch || hit.Checked {
			t.Fatalf("%q shows %+v, want an unchecked switch", label, hit)
		}
	}
	if grants := loader.remembered(); len(grants) != 0 {
		t.Fatalf("opening the page remembered %v", grants)
	}

	d.click(configure)
	d.until("the configure grant on", func() bool { return d.hit(configure).Checked })
	d.click(execute)
	d.until("the execute grant on", func() bool { return d.hit(execute).Checked })
	d.click(configure)
	d.until("the configure grant off", func() bool { return !d.hit(configure).Checked })

	if grants, want := loader.remembered(), [][2]bool{{true, false}, {true, true}, {false, true}}; !slices.Equal(grants, want) {
		t.Fatalf("the grants remembered %v, want %v", grants, want)
	}
}
