package workbench

import (
	"encoding/json"
	"strconv"
	"strings"
)

// debugJSONText renders the loaded variable tree as indented JSON, for the
// Variables section's JSON view. It reads only what the tree already holds: an
// unexpanded or unloaded container shows its adapter-formatted summary value, so
// the view never asks the adapter for more.
//
// A container whose children are all named "[n]" is an array, anything else an
// object. A scalar keeps the adapter's text: a JSON number, boolean, null or
// quoted string is emitted as it is, every other text (a class name, a pointer)
// becomes a JSON string.
func debugJSONText(scopes []*debugVarNode) string {
	var out strings.Builder
	out.WriteString("{")
	for index, scope := range scopes {
		if index > 0 {
			out.WriteString(",")
		}
		out.WriteString("\n  ")
		writeJSONString(&out, scope.name)
		out.WriteString(": ")
		writeJSONNode(&out, scope, 1)
	}
	if len(scopes) > 0 {
		out.WriteString("\n")
	}
	out.WriteString("}")
	return out.String()
}

func writeJSONNode(out *strings.Builder, node *debugVarNode, depth int) {
	if node.container == nil || len(node.container.nodes) == 0 || (!node.expanded && !node.scope) {
		writeJSONScalar(out, node.value, node.scope)
		return
	}
	children := node.container.nodes
	array := true
	for _, child := range children {
		if !isArrayIndex(child.name) {
			array = false
			break
		}
	}
	open, closing := "{", "}"
	if array {
		open, closing = "[", "]"
	}
	out.WriteString(open)
	for index, child := range children {
		if index > 0 {
			out.WriteString(",")
		}
		out.WriteString("\n")
		out.WriteString(strings.Repeat("  ", depth+1))
		if !array {
			writeJSONString(out, child.name)
			out.WriteString(": ")
		}
		writeJSONNode(out, child, depth+1)
	}
	out.WriteString("\n")
	out.WriteString(strings.Repeat("  ", depth))
	out.WriteString(closing)
}

// writeJSONScalar emits the adapter's text as a JSON value. A scope that was
// never loaded has no summary, so it is an empty object.
func writeJSONScalar(out *strings.Builder, text string, scope bool) {
	if scope && text == "" {
		out.WriteString("{}")
		return
	}
	trimmed := strings.TrimSpace(text)
	switch trimmed {
	case "null", "true", "false":
		out.WriteString(trimmed)
		return
	}
	if number, err := strconv.ParseFloat(trimmed, 64); err == nil && json.Valid([]byte(trimmed)) && !isNonFinite(number) {
		out.WriteString(trimmed)
		return
	}
	if strings.HasPrefix(trimmed, `"`) && json.Valid([]byte(trimmed)) {
		out.WriteString(trimmed)
		return
	}
	writeJSONString(out, text)
}

func isNonFinite(value float64) bool {
	return value != value || value > 1.7976931348623157e308 || value < -1.7976931348623157e308
}

func writeJSONString(out *strings.Builder, text string) {
	encoded, _ := json.Marshal(text)
	out.Write(encoded)
}

// isArrayIndex reports whether a child name is DAP's "[n]" index spelling.
func isArrayIndex(name string) bool {
	if len(name) < 3 || name[0] != '[' || name[len(name)-1] != ']' {
		return false
	}
	_, err := strconv.Atoi(name[1 : len(name)-1])
	return err == nil
}
