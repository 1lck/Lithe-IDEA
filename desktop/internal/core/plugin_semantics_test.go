package core

import (
	"context"
	"encoding/json"
	"testing"
)

func TestPluginSemanticLocationDecodesCoreShape(t *testing.T) {
	var locations struct {
		Locations []PluginSemanticLocation `json:"locations"`
	}
	body := `{"locations":[{"uri":"file:///work/A.java","filePath":"/work/A.java","range":{"start":{"line":2,"utf16Column":4},"end":{"line":2,"utf16Column":8}},"isReadOnly":false,"displayPath":null}]}`
	if err := json.Unmarshal([]byte(body), &locations); err != nil {
		t.Fatal(err)
	}
	if len(locations.Locations) != 1 {
		t.Fatalf("locations = %+v", locations.Locations)
	}
	location := locations.Locations[0]
	if location.FilePath != "/work/A.java" || location.Range.Start.Line != 2 || location.Range.Start.UTF16Column != 4 || location.IsReadOnly {
		t.Fatalf("location = %+v", location)
	}
}

func TestPluginCompletionItemKeepsCoreTextEdit(t *testing.T) {
	var result struct {
		Items []PluginSemanticCompletionItem `json:"items"`
	}
	body := `{"items":[{"label":"add","insertText":"add","insertTextFormat":2,"textEdit":{"range":{"start":{"line":1,"utf16Column":24},"end":{"line":1,"utf16Column":26}},"newText":"add(${1:int a})"}}],"isIncomplete":true}`
	if err := json.Unmarshal([]byte(body), &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Items) != 1 || result.Items[0].TextEdit == nil || result.Items[0].InsertTextFormat != 2 {
		t.Fatalf("items = %+v", result.Items)
	}
	if result.Items[0].TextEdit.NewText != "add(${1:int a})" {
		t.Fatalf("text edit = %+v", result.Items[0].TextEdit)
	}
}

func TestPluginTextEditRequestMatchesLSPShape(t *testing.T) {
	edit := PluginTextEdit{
		Range: PluginDocumentRange{
			Start: PluginDocumentPosition{Line: 0, UTF16Column: 1},
			End:   PluginDocumentPosition{Line: 0, UTF16Column: 3},
		},
		NewText: "x",
	}
	encoded, err := json.Marshal(edit)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"range":{"start":{"line":0,"utf16Column":1},"end":{"line":0,"utf16Column":3}},"newText":"x"}`
	if string(encoded) != want {
		t.Fatalf("edit = %s", encoded)
	}
}

func TestPlanPluginWorkspaceEditOrdersClosedFilesBeforeOpenDocuments(t *testing.T) {
	root := t.TempDir()
	edit := func(text string) []PluginTextEdit {
		return []PluginTextEdit{{NewText: text}}
	}
	changes := map[string][]PluginTextEdit{
		root + "/b.txt": edit("b"),
		root + "/a.txt": edit("a"),
	}
	plan, err := NewClient().PlanPluginWorkspaceEdit(context.Background(), root, changes, []PluginOpenDocument{{Path: root + "/a.txt"}})
	if err != nil {
		t.Fatal(err)
	}
	if plan.Rejection != nil || len(plan.Targets) != 2 {
		t.Fatalf("plan = %+v", plan)
	}
	if plan.Targets[0].Effect != "writeFile" || plan.Targets[1].Effect != "updateDocument" {
		t.Fatalf("commit order = %+v", plan.Targets)
	}
	outside, err := NewClient().PlanPluginWorkspaceEdit(context.Background(), root, map[string][]PluginTextEdit{"jdt://x": edit("z")}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if outside.Rejection == nil || outside.Rejection.Code != "outsideWorkspace" {
		t.Fatalf("outside = %+v", outside)
	}
}
