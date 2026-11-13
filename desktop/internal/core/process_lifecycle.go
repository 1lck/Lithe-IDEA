package core

import (
	"context"
	"encoding/json"
)

// ProcessRecord is one process or resource of this Lithe instance whose end
// Core decides. ID is host-chosen; Kind is run, terminal, agentTask,
// languageServer, debugAdapter, pluginTool, sidecar, daemon, container or
// oneShot; Ownership is launched, scopeToken, instanceLabel or unproven.
type ProcessRecord struct {
	ID                  string `json:"id"`
	Kind                string `json:"kind"`
	Ownership           string `json:"ownership"`
	DeclaredPolicy      string `json:"declaredPolicy,omitempty"`
	RecognizerID        string `json:"recognizerId,omitempty"`
	RecognizedPolicy    string `json:"recognizedPolicy,omitempty"`
	Detached            bool   `json:"detached,omitempty"`
	Idle                bool   `json:"idle,omitempty"`
	Retained            bool   `json:"retained,omitempty"`
	TerminationApproved bool   `json:"terminationApproved,omitempty"`
}

// ProcessDecision is what to do with one record. Action is terminate, confirm,
// ask, retain, defer, ignore or confirmStop; Reason is a stable log code.
type ProcessDecision struct {
	ID     string `json:"id"`
	Kind   string `json:"kind"`
	Policy string `json:"policy"`
	Action string `json:"action"`
	Reason string `json:"reason"`
}

// ProcessPlan is Core's exit plan: one decision per record in request order,
// how long an ordinary process gets to stop gracefully, and the rule that time
// follows.
type ProcessPlan struct {
	GracefulStopMilliseconds int               `json:"gracefulStopMilliseconds"`
	GracefulStopRule         GracefulStopRule  `json:"gracefulStopRule"`
	Decisions                []ProcessDecision `json:"decisions"`
}

// GracefulStopRule is Core's rule for the gracefulStopSeconds setting, in
// seconds: the time settings without one get, and the limits a stored time is
// kept within.
type GracefulStopRule struct {
	DefaultSeconds int `json:"defaultSeconds"`
	MinSeconds     int `json:"minSeconds"`
	MaxSeconds     int `json:"maxSeconds"`
}

// ResolveProcessLifecycle decides how each record ends in one context (quit,
// closeTerminalTab, agentDisconnect, crashRecovery, startupSweep, finalSweep
// or closeWorkspace). settings is the user's lifecycle settings document; nil
// takes the documented defaults.
func (c *Client) ResolveProcessLifecycle(ctx context.Context, lifecycleContext string, settings json.RawMessage, records []ProcessRecord) (ProcessPlan, error) {
	if records == nil {
		records = []ProcessRecord{}
	}
	request := struct {
		Context  string          `json:"context"`
		Settings json.RawMessage `json:"settings,omitempty"`
		Records  []ProcessRecord `json:"records"`
	}{lifecycleContext, settings, records}
	var plan ProcessPlan
	if err := c.Execute(ctx, "processLifecycle.resolve", request, &plan); err != nil {
		return ProcessPlan{}, err
	}
	return plan, nil
}

// ProcessSettlementDecision repeats a plan decision for settling.
type ProcessSettlementDecision struct {
	ID           string `json:"id"`
	Action       string `json:"action"`
	RecognizerID string `json:"recognizerId,omitempty"`
}

// ProcessSettlement is what ends, what is kept and the updated settings.
type ProcessSettlement struct {
	Terminate []string        `json:"terminate"`
	Keep      []string        `json:"keep"`
	Settings  json.RawMessage `json:"settings"`
}

// SettleProcessLifecycle turns the user's answers (id to "terminate" or "keep")
// into what ends and what stays. A confirmStop record is settled only after the
// user approved stopping it.
func (c *Client) SettleProcessLifecycle(ctx context.Context, settings json.RawMessage, decisions []ProcessSettlementDecision, answers map[string]string, remember bool) (ProcessSettlement, error) {
	if decisions == nil {
		decisions = []ProcessSettlementDecision{}
	}
	if answers == nil {
		answers = map[string]string{}
	}
	request := struct {
		Settings  json.RawMessage             `json:"settings,omitempty"`
		Decisions []ProcessSettlementDecision `json:"decisions"`
		Answers   map[string]string           `json:"answers"`
		Remember  bool                        `json:"remember"`
	}{settings, decisions, answers, remember}
	var result ProcessSettlement
	if err := c.Execute(ctx, "processLifecycle.settle", request, &result); err != nil {
		return ProcessSettlement{}, err
	}
	return result, nil
}
