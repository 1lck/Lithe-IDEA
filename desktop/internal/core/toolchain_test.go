package core

import (
	"context"
	"encoding/json"
	"os"
	"reflect"
	"testing"
	"time"
)

func TestToolchainPinEditingMatchesSharedFixture(t *testing.T) {
	data, err := os.ReadFile("../../../shared/fixtures/toolchain-pin-edit.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Request struct {
			Document  json.RawMessage    `json:"document"`
			Directory string             `json:"directory"`
			Edits     []ToolchainPinEdit `json:"edits"`
		} `json:"request"`
		Document any `json:"document"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	data, err = NewClient().EditToolchainPins(ctx, fixture.Request.Document, fixture.Request.Directory, fixture.Request.Edits)
	if err != nil {
		t.Fatal(err)
	}
	var got any
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, fixture.Document) {
		t.Fatalf("edited document = %s", data)
	}
}
