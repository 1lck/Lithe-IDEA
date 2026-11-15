package workbench

import (
	"encoding/json"
	"testing"
)

func TestDebugJSONTextMirrorsTheLoadedTree(t *testing.T) {
	list := &debugVarNode{name: "items", value: "ArrayList@1", ref: 7, expanded: true, depth: 1, container: &debugVarContainer{nodes: []*debugVarNode{
		{name: "[0]", value: "1"}, {name: "[1]", value: `"two"`},
	}}}
	collapsed := &debugVarNode{name: "later", value: "Node@9", ref: 9}
	locals := &debugVarNode{name: "Locals", scope: true, ref: 1, expanded: true, container: &debugVarContainer{nodes: []*debugVarNode{
		{name: "count", value: "42"},
		{name: "ok", value: "true"},
		{name: "text", value: "hello world"},
		{name: "nothing", value: "null"},
		list, collapsed,
	}}}
	unloaded := &debugVarNode{name: "Globals", scope: true, expensive: true, ref: 2}
	text := debugJSONText([]*debugVarNode{locals, unloaded})
	var got map[string]any
	if err := json.Unmarshal([]byte(text), &got); err != nil {
		t.Fatalf("not valid JSON: %v\n%s", err, text)
	}
	l := got["Locals"].(map[string]any)
	if l["count"] != float64(42) || l["ok"] != true || l["text"] != "hello world" || l["nothing"] != nil || l["later"] != "Node@9" {
		t.Fatalf("scalars wrong: %v", l)
	}
	items := l["items"].([]any)
	if len(items) != 2 || items[0] != float64(1) || items[1] != "two" {
		t.Fatalf("array wrong: %v", items)
	}
	if g, ok := got["Globals"].(map[string]any); !ok || len(g) != 0 {
		t.Fatalf("an unloaded scope must be empty: %v", got["Globals"])
	}
}

func TestDebugVariableKeyDistinguishesChildren(t *testing.T) {
	if debugVariableKey("a", "1", "int", "", 0) == debugVariableKey("a", "2", "int", "", 0) {
		t.Fatal("a changed value must be a new fingerprint")
	}
}
