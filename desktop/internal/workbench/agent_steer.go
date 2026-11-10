package workbench

import (
	"strings"
)

// Mid-turn steering sends supplementary input while the Agent works. Core owns
// the delivery rules (shared/contracts/rust-core-api.md): `ready.canSteer` says
// the Agent supports it, one supplementary request per session is outstanding, and
// the result is injected, promptRequired or failed. promptRequired leaves the
// input unconsumed, so it is submitted once as a normal prompt after the turn.

type agentDelivery uint8

const (
	agentDeliveryNone agentDelivery = iota
	// agentDeliveryPending: sent, waiting for Core's steeringResult.
	agentDeliveryPending
	// agentDeliveryReceived: upstream accepted it (not proof the model consumed it).
	agentDeliveryReceived
	// agentDeliveryQueued: the Agent left it unconsumed; it is sent after the turn.
	agentDeliveryQueued
	agentDeliveryFailed
)

// agentSteerState is the one outstanding supplementary request and the input
// waiting for the turn to end.
type agentSteerState struct {
	pendingToken string
	queued       *agentQueuedInput
}

type agentQueuedInput struct {
	Token string
	Text  string
	Files []agentFileRef
}

// agentCanSteer reports that the composer can send supplementary input now.
func (a *App) agentCanSteer(p *project) bool {
	if p == nil || p.agent.conn == nil || p.agent.sessionID == "" || !p.agent.activity.canSteer ||
		p.agent.phase != agentPhaseBusy || p.agent.permission != nil || p.agent.steer.pendingToken != "" ||
		p.agent.steer.queued != nil || p.agent.auth != agentAuthNone {
		return false
	}
	return strings.TrimSpace(p.agent.editor.CommittedString()) != "" || len(p.agent.files) > 0
}

// steerAgent sends the draft as supplementary input to the running turn.
func (a *App) steerAgent(p *project) {
	if !a.agentCanSteer(p) {
		return
	}
	value := strings.TrimSpace(p.agent.editor.CommittedString())
	files := append([]agentFileRef(nil), p.agent.files...)
	token := a.agentCommandToken(p, "steer")
	command := map[string]any{"kind": "steer", "token": token, "sessionId": p.agent.sessionID, "text": value}
	if wire := agentFileWire(files); wire != nil {
		command["files"] = wire
	}
	if err := a.sendAgentCommand(p, command); err != nil {
		p.agent.err = a.agentSessionError(err)
		p.agent.phase = agentPhaseFailed
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_steer", err))
		return
	}
	p.agent.steer.pendingToken = token
	p.agent.messages = append(p.agent.messages, agentMessage{
		Role: agentRoleUser, Text: value, Files: files, Delivery: agentDeliveryPending, DeliveryToken: token,
	})
	p.agent.bytes += len(value)
	p.agent.resetComposer()
	p.agent.files = nil
	a.trimAgentTranscript(p)
	a.performed("agent.steer", surfaceButton)
}

// applyAgentSteeringResult records Core's answer to the outstanding request. A late
// answer for another token is ignored.
func (a *App) applyAgentSteeringResult(p *project, conn *agentConnection, token, sessionID, outcome, message string) {
	if token == "" || token != p.agent.steer.pendingToken || !agentEventForCurrentSession(p, sessionID) {
		return
	}
	p.agent.steer.pendingToken = ""
	row := -1
	for i := len(p.agent.messages) - 1; i >= 0; i-- {
		if p.agent.messages[i].DeliveryToken == token {
			row = i
			break
		}
	}
	switch outcome {
	case "injected":
		if row >= 0 {
			p.agent.messages[row].Delivery = agentDeliveryReceived
		}
	case "promptRequired":
		if row < 0 {
			return
		}
		m := &p.agent.messages[row]
		m.Delivery = agentDeliveryQueued
		p.agent.steer.queued = &agentQueuedInput{Token: token, Text: m.Text, Files: m.Files}
		// A turn that already ended while the answer was in flight has nothing to wait for.
		if p.agent.phase == agentPhaseReady {
			a.agentTurnEnded(p, conn)
		}
	default:
		if row >= 0 {
			p.agent.messages[row].Delivery = agentDeliveryFailed
		}
		a.emit(operationFailedLevel, operationFailedEvent, map[string]any{"operation": "agent_steer_result"})
		if strings.TrimSpace(message) != "" {
			p.agent.err = message
		}
	}
}

// agentTurnEnded submits input the Agent left unconsumed, once, as a normal prompt.
func (a *App) agentTurnEnded(p *project, conn *agentConnection) {
	queued := p.agent.steer.queued
	if queued == nil || p.agent.conn != conn || p.agent.sessionID == "" {
		return
	}
	p.agent.steer.queued = nil
	command := map[string]any{"kind": "prompt", "sessionId": p.agent.sessionID, "text": queued.Text}
	if wire := agentFileWire(queued.Files); wire != nil {
		command["files"] = wire
	}
	for i := len(p.agent.messages) - 1; i >= 0; i-- {
		if p.agent.messages[i].DeliveryToken == queued.Token {
			p.agent.messages[i].Delivery = agentDeliveryNone
			break
		}
	}
	if err := a.sendAgentCommand(p, command); err != nil {
		p.agent.err = a.agentSessionError(err)
		p.agent.phase = agentPhaseFailed
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_steer_prompt", err))
		return
	}
	p.agent.phase = agentPhaseBusy
}

// dropAgentSteer forgets supplementary input state; Stop and a closed connection
// revoke the fallback so a stopped turn is never continued by itself.
func (s *agentSteerState) drop() { *s = agentSteerState{} }
