package settingswindow

import (
	"slices"
	"sync"
	"testing"

	"github.com/vivaui/viva/gfx"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// fakeAgentSessions is the workbench side of the Agents page: it records each choice and
// shows it in the next State, as the workbench does once it saved the choice.
type fakeAgentSessions struct {
	mu      sync.Mutex
	state   AgentSessionsState
	allowed []string
	search  []bool
}

func (f *fakeAgentSessions) State() AgentSessionsState {
	f.mu.Lock()
	defer f.mu.Unlock()
	state := f.state
	state.Plugins = slices.Clone(f.state.Plugins)
	return state
}

func (f *fakeAgentSessions) SetAllowed(pluginID string, allowed bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	word := "off"
	if allowed {
		word = "on"
	}
	f.allowed = append(f.allowed, pluginID+"="+word)
	for i := range f.state.Plugins {
		if f.state.Plugins[i].PluginID == pluginID {
			f.state.Plugins[i].Allowed = allowed
		}
	}
}

func (f *fakeAgentSessions) SetMCPSearch(allowed bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.search = append(f.search, allowed)
	f.state.MCPSearch = allowed
}

func (f *fakeAgentSessions) choices() ([]string, []bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.allowed), slices.Clone(f.search)
}

// TestAgentsSwitchesApplyWhenFlipped covers the Agents page's switches: opening the page
// writes nothing, and each click on a plugin's switch or the MCP search switch reaches the
// workbench once with the flipped value, which the switch then shows.
func TestAgentsSwitchesApplyWhenFlipped(t *testing.T) {
	loader := &fakeAgentSessions{state: AgentSessionsState{Loaded: true, Plugins: []AgentSessionPlugin{
		{PluginID: "dev.lithe.test.agent", Name: "Test Agent Plugin", Agents: []string{"Test Agent"}},
	}}}
	w := newWindow(NewController(Options{Agents: loader}), Values{})
	w.sess.page = pageAgents
	d := openWindow(t, w)
	search := i18n.Shared(w.marketLanguage(), "desktop.agents.settings.mcpSearchSwitch")

	for _, label := range []string{"Test Agent Plugin", search} {
		if hit := d.hit(label); hit.Role != gfx.RoleSwitch || hit.Checked {
			t.Fatalf("%q shows %+v, want an unchecked switch", label, hit)
		}
	}
	if allowed, searches := loader.choices(); len(allowed) != 0 || len(searches) != 0 {
		t.Fatalf("opening the page wrote %v and %v", allowed, searches)
	}

	d.click("Test Agent Plugin")
	d.until("the plugin's switch on", func() bool { return d.hit("Test Agent Plugin").Checked })
	d.click(search)
	d.until("the search switch on", func() bool { return d.hit(search).Checked })
	d.click("Test Agent Plugin")
	d.until("the plugin's switch off", func() bool { return !d.hit("Test Agent Plugin").Checked })

	allowed, searches := loader.choices()
	if want := []string{"dev.lithe.test.agent=on", "dev.lithe.test.agent=off"}; !slices.Equal(allowed, want) {
		t.Fatalf("the plugin's switch wrote %v, want %v", allowed, want)
	}
	if want := []bool{true}; !slices.Equal(searches, want) {
		t.Fatalf("the search switch wrote %v, want %v", searches, want)
	}
}
