package pluginview

import (
	"bytes"
	"encoding/json"
	"os"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

// viewCase is one case of the contract's view-results fixture.
type viewCase struct {
	Name   string          `json:"name"`
	View   json.RawMessage `json:"view"`
	Result struct {
		View json.RawMessage `json:"view"`
	} `json:"result"`
	Expected struct {
		Status string          `json:"status"`
		View   json.RawMessage `json:"view"`
	} `json:"expected"`
}

// strictNodes decodes a view refusing any field Node does not read, so a field the contract
// adds is a failing test here rather than a view the host draws without it.
func strictNodes(t *testing.T, view json.RawMessage) []Node {
	t.Helper()
	decoder := json.NewDecoder(bytes.NewReader(view))
	decoder.DisallowUnknownFields()
	var nodes []Node
	if err := decoder.Decode(&nodes); err != nil {
		t.Fatalf("decode %s: %v", view, err)
	}
	return nodes
}

func TestDecodeReadsEveryFieldOfTheContractViews(t *testing.T) {
	data, err := os.ReadFile(contractfixture.Path("fixtures/ui/view-results.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []viewCase `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	types := map[string]bool{}
	var walk func([]Node)
	walk = func(nodes []Node) {
		for _, n := range nodes {
			types[n.Type] = true
			walk(n.Children)
		}
	}
	checked := 0
	for _, c := range fixture.Cases {
		if c.Expected.Status != "ok" {
			continue
		}
		views := []json.RawMessage{c.View}
		if string(c.Expected.View) == `"result.view"` {
			views = append(views, c.Result.View)
		} else {
			views = append(views, c.Expected.View)
		}
		for _, view := range views {
			if len(view) == 0 {
				continue
			}
			strict := strictNodes(t, view)
			decoded, err := Decode(view)
			if err != nil || len(decoded) != len(strict) {
				t.Fatalf("%s: Decode = %d nodes, %v; want %d", c.Name, len(decoded), err, len(strict))
			}
			walk(strict)
			checked++
		}
	}
	if checked == 0 {
		t.Fatal("the fixture has no view the host can draw")
	}
	for _, want := range []string{"section", "row", "label", "button", "tree", "toggle", "tool", "canvas"} {
		if !types[want] {
			t.Errorf("the fixture views have no %s node", want)
		}
	}
}

func TestDecodeRefusesWhatIsNotANodeList(t *testing.T) {
	for _, view := range []string{"", `{"type":"label"}`, `"label"`, `[{"type":1}]`} {
		if _, err := Decode(json.RawMessage(view)); err == nil {
			t.Errorf("Decode(%q) read a view", view)
		}
	}
	if nodes, err := Decode(json.RawMessage(`[]`)); err != nil || len(nodes) != 0 {
		t.Errorf("an empty view = %v, %v", nodes, err)
	}
}

func TestNodeValuesDefaultWhenAbsent(t *testing.T) {
	nodes := strictNodes(t, json.RawMessage(`[
		{"type":"textField","value":"main","width":"fill"},
		{"type":"toggle","value":true,"enabled":false},
		{"type":"label","width":12},
		{"type":"textField","value":true},
		{"type":"label"}
	]`))
	field, toggle, label, mistyped, bare := nodes[0], nodes[1], nodes[2], nodes[3], nodes[4]
	if field.stringValue() != "main" || !field.enabled() {
		t.Errorf("text field value %q, enabled %v", field.stringValue(), field.enabled())
	}
	if count, fill := field.characters(); count != 0 || !fill {
		t.Errorf("fill width = %d, %v", count, fill)
	}
	if !toggle.boolValue() || toggle.enabled() {
		t.Errorf("toggle value %v, enabled %v", toggle.boolValue(), toggle.enabled())
	}
	if count, fill := label.characters(); count != 12 || fill {
		t.Errorf("label width = %d, %v", count, fill)
	}
	if mistyped.stringValue() != "" || bare.boolValue() || bare.stringValue() != "" {
		t.Error("a missing or mistyped value was read")
	}
	if count, fill := bare.characters(); count != 0 || fill {
		t.Errorf("no width = %d, %v", count, fill)
	}
}

func TestShapeDefaults(t *testing.T) {
	half, two, three := 0.5, 2.0, 3.0
	var bare Shape
	if bare.opacity() != 1 || bare.strokeWidth() != 1 || bare.scale() != 1 || bare.clickable() {
		t.Errorf("bare shape: opacity %v, stroke %v, scale %v, clickable %v", bare.opacity(), bare.strokeWidth(), bare.scale(), bare.clickable())
	}
	set := Shape{Type: "group", Opacity: &half, Width: &two, Scale: &three, On: []string{"click"}}
	if set.opacity() != 0.5 || set.strokeWidth() != 2 || set.scale() != 3 || !set.clickable() {
		t.Errorf("set shape: opacity %v, stroke %v, scale %v, clickable %v", set.opacity(), set.strokeWidth(), set.scale(), set.clickable())
	}
	if (&Shape{Type: "rect", On: []string{"click"}}).clickable() {
		t.Error("a rect with events is a control; only groups are")
	}
}

func TestHostIconDrawsEveryNameTheContractLists(t *testing.T) {
	data, err := os.ReadFile(contractfixture.Path("plugin-manifest.schema.json"))
	if err != nil {
		t.Fatal(err)
	}
	var schema struct {
		Defs struct {
			UIIcon struct {
				Properties struct {
					Host struct {
						Enum []string `json:"enum"`
					} `json:"host"`
				} `json:"properties"`
			} `json:"uiIcon"`
		} `json:"$defs"`
	}
	if err := json.Unmarshal(data, &schema); err != nil {
		t.Fatal(err)
	}
	names := schema.Defs.UIIcon.Properties.Host.Enum
	if len(names) == 0 {
		t.Fatal("the manifest schema lists no host icon")
	}
	for _, name := range names {
		if icon, ok := HostIcon(name); !ok || len(icon.Commands) == 0 {
			t.Errorf("host icon %q is not drawn", name)
		}
	}
	if _, ok := HostIcon("not-an-icon"); ok {
		t.Error("an unknown icon name resolved")
	}
}
