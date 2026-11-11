package workbench

import (
	"encoding/json"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// One Agent-declared session configuration option. The adapter owns the list,
// names, order and current value; the panel only presents the select options Core
// can set through its setConfigOption command and never invents a catalog.
type agentConfigOption struct {
	ID       string
	Name     string
	Category string
	Current  string
	Choices  []agentConfigChoice
	// choiceIndexes lists the choices by index and pick is the one the drop-down shows,
	// set from Current at each paint: the drop-down edits pick and a change is the
	// user's choice.
	choiceIndexes []int
	pick          int
	// open says the approval-mode menu is showing.
	open bool
}

type agentConfigChoice struct {
	Value string
	Name  string
	// Description is the Agent's own one-line explanation of the choice, empty if none.
	Description string
	// Group is the name of the Agent's group this choice belongs to, empty if ungrouped.
	Group string
}

// agentSessionConfig is one connection's session settings. It is replaced
// whenever the Agent reports a new confirmed catalog and cleared with the
// project, so a stale catalog cannot be shown for another session.
type agentSessionConfig struct {
	options []agentConfigOption

	pendingToken string
	err          string
}

func newAgentSessionConfig() agentSessionConfig {
	return agentSessionConfig{}
}

func (c *agentSessionConfig) reset() { *c = newAgentSessionConfig() }

// agentConfigOptionWire mirrors the ACP SessionConfigOption shape Core forwards.
type agentConfigOptionWire struct {
	ID           string          `json:"id"`
	Name         string          `json:"name"`
	Category     string          `json:"category"`
	Type         string          `json:"type"`
	CurrentValue any             `json:"currentValue"`
	Options      json.RawMessage `json:"options"`
}

type agentConfigChoiceWire struct {
	Value       string `json:"value"`
	Name        string `json:"name"`
	Description string `json:"description"`
}

type agentConfigGroupWire struct {
	Group   string                  `json:"group"`
	Name    string                  `json:"name"`
	Options []agentConfigChoiceWire `json:"options"`
}

// agentConfigCategories maps the ACP semantic category to the panel's label.
// Unknown categories keep the adapter's own option name.
var agentConfigCategories = map[string]string{
	"model":         "model",
	"thought_level": "thinking",
	"mode":          "permissions",
}

// applyAgentConfigOptions replaces the catalog with the latest one the Agent
// confirmed. Options that are not select values are omitted because Core's
// setConfigOption command carries a string value.
func (a *App) applyAgentConfigOptions(p *project, raw json.RawMessage) {
	c := &p.agent.config
	c.pendingToken = ""
	c.err = ""
	a.replaceAgentConfigOptions(p, raw)
}

// replaceAgentConfigOptions swaps in the Agent's full option list without touching
// the panel's own pending command. The Agent-initiated config_option_update uses it,
// so a mode the Agent switched itself is shown without cancelling a request in flight.
func (a *App) replaceAgentConfigOptions(p *project, raw json.RawMessage) {
	c := &p.agent.config
	if len(raw) == 0 || string(raw) == "null" {
		c.options = nil
		return
	}
	var wire []agentConfigOptionWire
	if err := json.Unmarshal(raw, &wire); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_config_decode", err))
		return
	}
	options := make([]agentConfigOption, 0, len(wire))
	for _, entry := range wire {
		if entry.ID == "" || entry.Type != "select" {
			continue
		}
		current, _ := entry.CurrentValue.(string)
		option := agentConfigOption{
			ID:       entry.ID,
			Name:     entry.Name,
			Category: entry.Category,
			Current:  current,
			Choices:  decodeAgentConfigChoices(entry.Options),
		}
		if option.Name == "" {
			option.Name = entry.ID
		}
		option.choiceIndexes = make([]int, len(option.Choices))
		for i := range option.choiceIndexes {
			option.choiceIndexes[i] = i
		}
		options = append(options, option)
	}
	previous := c.options
	c.options = options
	a.reconcileAgentNotice(p, previous, options)
}

// decodeAgentConfigChoices flattens ACP's ungrouped or grouped value list while
// preserving upstream order. A value the Agent declared without a name is shown
// by its identifier rather than hidden.
func decodeAgentConfigChoices(raw json.RawMessage) []agentConfigChoice {
	if len(raw) == 0 {
		return nil
	}
	var entries []json.RawMessage
	if err := json.Unmarshal(raw, &entries); err != nil {
		return nil
	}
	choices := make([]agentConfigChoice, 0, len(entries))
	for _, entry := range entries {
		var group agentConfigGroupWire
		if err := json.Unmarshal(entry, &group); err == nil && group.Group != "" {
			for _, choice := range group.Options {
				choices = appendAgentConfigChoice(choices, choice, group.groupName())
			}
			continue
		}
		var choice agentConfigChoiceWire
		if err := json.Unmarshal(entry, &choice); err != nil {
			continue
		}
		choices = appendAgentConfigChoice(choices, choice, "")
	}
	return choices
}

func appendAgentConfigChoice(choices []agentConfigChoice, choice agentConfigChoiceWire, group string) []agentConfigChoice {
	if choice.Value == "" {
		return choices
	}
	if choice.Name == "" {
		choice.Name = choice.Value
	}
	return append(choices, agentConfigChoice{Value: choice.Value, Name: choice.Name, Description: choice.Description, Group: group})
}

// agentConfigCurrentName is the display name of the confirmed value. A value
// outside the declared catalog stays visible as the Agent's own identifier.
func agentConfigCurrentName(option agentConfigOption) string {
	for _, choice := range option.Choices {
		if choice.Value == option.Current {
			return choice.Name
		}
	}
	return option.Current
}

// agentConfigChoiceIndex is the picker's selected row, or -1 when the confirmed
// value is outside the catalog (the trigger then shows it as a placeholder).
func agentConfigChoiceIndex(option agentConfigOption) int {
	for i, choice := range option.Choices {
		if choice.Value == option.Current {
			return i
		}
	}
	return -1
}

// selectAgentConfig sends one explicit user choice to Core. The panel never
// assumes success: the Agent's confirmed catalog arrives in sessionConfigured.
func (a *App) selectAgentConfig(p *project, optionID, value string) {
	if p == nil || p.agent.conn == nil || p.agent.sessionID == "" || optionID == "" || value == "" {
		return
	}
	if p.agent.phase != agentPhaseReady || p.agent.history.restoring() || p.agent.config.pendingToken != "" {
		return
	}
	var option *agentConfigOption
	for i := range p.agent.config.options {
		if p.agent.config.options[i].ID == optionID {
			option = &p.agent.config.options[i]
			break
		}
	}
	if option == nil || option.Current == value {
		return
	}
	token := a.agentCommandToken(p, "config")
	p.agent.config.pendingToken = token
	p.agent.config.err = ""
	if err := a.sendAgentCommand(p, map[string]any{
		"kind": "setConfigOption", "token": token, "sessionId": p.agent.sessionID,
		"configId": optionID, "value": value,
	}); err != nil {
		p.agent.config.pendingToken = ""
		p.agent.config.err = a.text.Agent.ConfigFailed
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_config", err))
		return
	}
	a.performed("agent.config.change", surfaceButton)
}

// applyAgentSessionConfigured accepts only the answer to the current request.
func (a *App) applyAgentSessionConfigured(p *project, token, sessionID string, configOptions json.RawMessage) {
	c := &p.agent.config
	if token == "" || token != c.pendingToken {
		return
	}
	c.pendingToken = ""
	if p.agent.sessionID != "" && sessionID != "" && sessionID != p.agent.sessionID {
		return
	}
	a.applyAgentConfigOptions(p, configOptions)
	a.performed("agent.config.applied", surfaceButton)
}

// agentAuthState is the connection's sign-in state as Core reported it. The panel
// never starts an authentication flow on its own and never reads account data.
type agentAuthState uint8

const (
	agentAuthNone agentAuthState = iota
	agentAuthRequired
	agentAuthSigningIn
)

// applyAgentAuthentication keeps an upstream sign-in requirement visible instead
// of treating the connection as ready or as a generic failure.
func (a *App) applyAgentAuthentication(p *project, kind string) {
	switch kind {
	case "authenticationRequired":
		p.agent.auth = agentAuthRequired
		p.agent.connecting = false
		p.agent.pending = ""
		p.agent.phase = agentPhaseFailed
		p.agent.err = a.text.Agent.AuthenticationRequired
		a.emit(core.LevelWarn, operationFailedEvent, map[string]any{"operation": "agent_auth"})
	case "authenticating":
		p.agent.auth = agentAuthSigningIn
		p.agent.connecting = false
		p.agent.phase = agentPhaseStarting
		p.agent.err = ""
	}
}

func (a *App) clearAgentAuthentication(p *project) {
	if p != nil {
		p.agent.auth = agentAuthNone
	}
}

// groupName is the heading of an ACP group: its display name, or its identifier when the
// Agent gave no name.
func (g agentConfigGroupWire) groupName() string {
	if g.Name != "" {
		return g.Name
	}
	return g.Group
}
