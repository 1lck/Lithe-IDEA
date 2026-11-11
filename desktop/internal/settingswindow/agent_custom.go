package settingswindow

import (
	"path/filepath"
	"strings"
)

// Custom Agents are command-line ACP agents the user configured. Their definitions are
// Lithe's own preferences: the window reads the saved list on every paint and writes the whole
// list back through the owner, so the page always shows what is stored. Core launches them
// with `command`, `args` and `cwd` (launch contract); nothing here starts a process.

// CustomAgentSetting is one saved custom Agent definition.
type CustomAgentSetting struct {
	ID               string   `json:"id"`
	Name             string   `json:"name"`
	Command          string   `json:"command"`
	Args             []string `json:"args,omitempty"`
	WorkingDirectory string   `json:"workingDirectory,omitempty"`
}

// customAgentDraft is the editor's text. Only the settings window thread reads it.
type customAgentDraft struct {
	editing         bool
	id              string
	name, command   string
	args, directory string
	err             string
	confirmRemove   string
}

// customAgentArgs splits the args field into one argument per non-empty line.
func customAgentArgs(text string) []string {
	var args []string
	for _, line := range strings.Split(text, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			args = append(args, line)
		}
	}
	return args
}

// validateCustomAgent returns the message key of the first rule the draft breaks, or "".
func validateCustomAgent(d customAgentDraft) string {
	switch {
	case strings.TrimSpace(d.name) == "":
		return "desktop.settings.agent.custom.nameRequired"
	case strings.TrimSpace(d.command) == "":
		return "desktop.settings.agent.custom.commandRequired"
	case strings.TrimSpace(d.directory) != "" && !filepath.IsAbs(strings.TrimSpace(d.directory)):
		return "desktop.settings.agent.custom.directoryAbsolute"
	}
	return ""
}

// saveCustomAgent writes the draft into the saved list and asks the owner to store it.
func (s *agentSettings) saveCustomAgent(list []CustomAgentSetting) {
	s.mu.Lock()
	d := s.custom
	s.mu.Unlock()
	if key := validateCustomAgent(d); key != "" {
		s.mu.Lock()
		s.custom.err = key
		s.mu.Unlock()
		return
	}
	entry := CustomAgentSetting{
		ID: d.id, Name: strings.TrimSpace(d.name), Command: strings.TrimSpace(d.command),
		Args: customAgentArgs(d.args), WorkingDirectory: strings.TrimSpace(d.directory),
	}
	if entry.ID == "" {
		entry.ID = newHookID()
	}
	next := make([]CustomAgentSetting, 0, len(list)+1)
	replaced := false
	for _, existing := range list {
		if existing.ID == entry.ID {
			next = append(next, entry)
			replaced = true
			continue
		}
		next = append(next, existing)
	}
	if !replaced {
		next = append(next, entry)
	}
	s.mu.Lock()
	s.custom = customAgentDraft{}
	s.mu.Unlock()
	if s.setCustomAgents != nil {
		s.setCustomAgents(next)
	}
}

// removeCustomAgent drops one definition after the user confirmed it.
func (s *agentSettings) removeCustomAgent(list []CustomAgentSetting, id string) {
	next := make([]CustomAgentSetting, 0, len(list))
	for _, existing := range list {
		if existing.ID != id {
			next = append(next, existing)
		}
	}
	s.mu.Lock()
	s.custom.confirmRemove = ""
	s.mu.Unlock()
	if s.setCustomAgents != nil {
		s.setCustomAgents(next)
	}
}

// editCustomAgent opens the form on one definition, or on an empty one when entry is nil.
func (s *agentSettings) editCustomAgent(entry *CustomAgentSetting) {
	d := customAgentDraft{editing: true}
	if entry != nil {
		d.id, d.name, d.command = entry.ID, entry.Name, entry.Command
		d.args = strings.Join(entry.Args, "\n")
		d.directory = entry.WorkingDirectory
	}
	s.mu.Lock()
	s.custom = d
	s.mu.Unlock()
}

// cancelCustomAgent closes the form without storing anything.
func (s *agentSettings) cancelCustomAgent() {
	s.mu.Lock()
	s.custom = customAgentDraft{}
	s.mu.Unlock()
}
