package syntax

import (
	"context"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
)

// CandidateSnapshot holds a bounded prefix. Reasons describe why the remaining suffix
// cannot be trusted; the owning workbench records each degradation at its boundary.
type CandidateSnapshot struct {
	Brackets  []Bracket
	Variables []Variable
	Reasons   []string
}

type candidatePart struct {
	bracketStart, variableStart       int
	base                              int
	start, end                        candidateLexState
	brackets                          []Bracket
	variables                         []Variable
	roles                             []uint8
	reason                            string
	bracketsOmitted, variablesOmitted bool
}

type candidateIndex struct {
	enabled bool
	parts   []candidatePart
	wake    chan struct{}
}

func (c *candidateIndex) notify() {
	if c.wake != nil {
		close(c.wake)
		c.wake = nil
	}
}
func (c *candidateIndex) reset(enabled bool) {
	c.notify()
	c.enabled = enabled
	c.parts = nil
	if enabled {
		c.parts = make([]candidatePart, 1)
	}
}
func (c *candidateIndex) insert(i int) {
	if !c.enabled {
		return
	}
	c.parts = slices.Insert(c.parts, i+1, candidatePart{})
}
func (c *candidateIndex) remove(from, through int) {
	c.notify()
	if c.enabled && through > from {
		c.parts = slices.Delete(c.parts, from, through)
	}
}

// room bounds storage across the entire document, including segments already cached.
// Only the worker calls this; changing a prefix never makes the UI scan candidate lists.
func (c *candidateIndex) room(before int) (int, int) {
	part := c.parts[before]
	return rainbowBracketMaxCount - part.bracketStart, rainbowVariableMaxCount - part.variableStart
}

// bound evicts an overflowing suffix after a prefix edit. When deletion opens space,
// only the first incomplete segment becomes dirty; ordinary cached segments stay intact.
func (c *candidateIndex) bound(cp *checkpoints, from int) {
	brackets, variables := c.room(from)
	for i := from; i < len(c.parts); i++ {
		part := &c.parts[i]
		if i > from && part.bracketStart == rainbowBracketMaxCount-brackets && part.variableStart == rainbowVariableMaxCount-variables {
			break
		}
		part.bracketStart, part.variableStart = rainbowBracketMaxCount-brackets, rainbowVariableMaxCount-variables
		refill := part.bracketsOmitted && len(part.brackets) < brackets ||
			part.variablesOmitted && len(part.variables) < variables
		if len(part.brackets) > brackets {
			part.brackets = slices.Clone(part.brackets[:brackets])
			part.bracketsOmitted = true
		}
		if len(part.variables) > variables {
			part.variables = slices.Clone(part.variables[:variables])
			part.roles = slices.Clone(part.roles[:variables])
			part.variablesOmitted = true
		}
		brackets -= len(part.brackets)
		variables -= len(part.variables)
		if refill {
			cp.dirty[i] = true
			cp.firstDirty = min(cp.firstDirty, i)
		}
	}
}

// Candidates waits for the same highlighter worker that colors the document. It never
// tokenizes or holds the UI lock while aggregating document-wide declarations and ranges.
func (h *Highlighter) Candidates(ctx context.Context, text rope.Rope) (CandidateSnapshot, error) {
	for {
		h.mu.Lock()
		if !h.text.Same(text) {
			h.mu.Unlock()
			return CandidateSnapshot{}, context.Canceled
		}
		if !h.candidates.enabled {
			h.mu.Unlock()
			return CandidateSnapshot{}, nil
		}
		if h.cp.firstDirty >= len(h.cp.lines) {
			parts := slices.Clone(h.candidates.parts)
			lines := slices.Clone(h.cp.lines)
			h.mu.Unlock()
			return gatherCandidates(ctx, text, parts, lines)
		}
		if h.closed {
			h.mu.Unlock()
			return CandidateSnapshot{}, context.Canceled
		}
		if h.candidates.wake == nil {
			h.candidates.wake = make(chan struct{})
		}
		wake := h.candidates.wake
		h.mu.Unlock()
		select {
		case <-ctx.Done():
			return CandidateSnapshot{}, ctx.Err()
		case <-wake:
		}
	}
}

func gatherCandidates(ctx context.Context, text rope.Rope, parts []candidatePart, lines []int32) (CandidateSnapshot, error) {
	var result CandidateSnapshot
	declared := make(map[string]struct{})
	bracketCount, variableCount := 0, 0
	for _, part := range parts {
		if err := ctx.Err(); err != nil {
			return CandidateSnapshot{}, err
		}
		for i, variable := range part.variables {
			if part.roles[i]&candidateDeclaration != 0 {
				declared[variable.Name] = struct{}{}
			}
		}
		bracketCount += len(part.brackets)
		variableCount += len(part.variables)
		if part.reason != "" {
			break
		}
	}
	result.Brackets = make([]Bracket, 0, min(rainbowBracketMaxCount, bracketCount))
	result.Variables = make([]Variable, 0, min(rainbowVariableMaxCount, variableCount))
	bracketsFull, variablesFull := false, false
	reason := func(value string) {
		if !slices.Contains(result.Reasons, value) {
			result.Reasons = append(result.Reasons, value)
		}
	}
	for n, part := range parts {
		if err := ctx.Err(); err != nil {
			return CandidateSnapshot{}, err
		}
		delta := text.LineStart(int(lines[n])) - part.base
		if part.bracketsOmitted {
			reason("bracket_limit")
		}
		if part.variablesOmitted {
			reason("variable_limit")
		}
		if !bracketsFull {
			for _, bracket := range part.brackets {
				if len(result.Brackets) == rainbowBracketMaxCount {
					bracketsFull = true
					reason("bracket_limit")
					break
				}
				bracket.Offset = uint32(int(bracket.Offset) + delta)
				result.Brackets = append(result.Brackets, bracket)
			}
		}
		if !variablesFull {
			for i, variable := range part.variables {
				if part.roles[i]&(candidateNeedsDeclaration|candidateQualifier) != 0 {
					if _, ok := declared[variable.Name]; !ok {
						continue
					}
				}
				if len(result.Variables) == rainbowVariableMaxCount {
					variablesFull = true
					reason("variable_limit")
					break
				}
				variable.Start = uint32(int(variable.Start) + delta)
				variable.End = uint32(int(variable.End) + delta)
				result.Variables = append(result.Variables, variable)
			}
		}
		if part.reason != "" {
			reason(part.reason)
			break
		}
	}
	return result, nil
}
