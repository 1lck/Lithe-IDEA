//go:build linux

// The fixture implements a tiny native configuration format on the SSH host.
package main

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

type request struct {
	Operation  string            `json:"operation"`
	SourceID   string            `json:"sourceID"`
	Revision   string            `json:"revision"`
	Values     map[string]string `json:"values"`
	HostPath   string            `json:"hostPath"`
	OutputFile string            `json:"outputFile"`
}

type source struct {
	ID       string
	Scope    string
	Path     string
	HostPath string
	Writable bool
}

func main() {
	err := run()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	if len(os.Args) != 3 {
		return errors.New("expected a home fixture name and a request file")
	}
	root, err := os.Getwd()
	if err != nil {
		return err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	homeFile, input := os.Args[1], os.Args[2]
	sources := []source{
		{"project", "workspace", "project.fixture", filepath.Join(root, "project.fixture"), true},
		{"user", "home", homeFile, filepath.Join(home, homeFile), true},
		{"defaults", "hostReadOnly", filepath.Join(root, "defaults.fixture"), filepath.Join(root, "defaults.fixture"), false},
	}
	data, err := os.ReadFile(input)
	if err != nil {
		return err
	}
	var req request
	if err := json.Unmarshal(data, &req); err != nil {
		return err
	}
	if req.Operation == "editSource" {
		for _, entry := range sources {
			if entry.ID == req.SourceID && entry.Writable && entry.HostPath == req.HostPath {
				return edit(req, root, input)
			}
		}
		return errors.New("unrecognized edit target")
	}
	if req.Operation != "read" && req.Operation != "readAfterSave" {
		return errors.New("unrecognized operation")
	}
	return read(sources, req.Operation, input)
}

func read(sources []source, operation, input string) error {
	projection := make([]map[string]any, 0, len(sources))
	for _, entry := range sources {
		value, revision, err := readSource(entry.HostPath)
		if err != nil {
			return err
		}
		projection = append(projection, map[string]any{
			"id": entry.ID, "group": "general", "title": entry.ID,
			"path": entry.Path, "scope": entry.Scope, "revision": revision, "writable": entry.Writable,
			"fields": []map[string]any{{
				"id": "name", "title": "Name", "kind": "text",
				"value": value, "effectiveValue": value, "effectiveSource": entry.ID,
			}},
		})
	}
	if err := os.WriteFile("last-read", []byte(operation+"\n"+input), 0o600); err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"format": "litheSettingsSources", "version": 0, "title": "Remote fixture settings",
		"groups":  []map[string]any{{"id": "general", "title": "General", "layout": "form"}},
		"sources": projection,
	})
}

func edit(req request, root, input string) error {
	_, revision, err := readSource(req.HostPath)
	if err != nil {
		return err
	}
	if revision != req.Revision {
		return errors.New("source changed")
	}
	value := req.Values["name"]
	if err := os.WriteFile(filepath.Join(root, "last-edit"), []byte(input+"\n"+req.OutputFile), 0o600); err != nil {
		return err
	}
	file, err := os.OpenFile(req.OutputFile, os.O_WRONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return err
	}
	_, writeErr := file.WriteString(value)
	if err := errors.Join(writeErr, file.Close()); err != nil {
		return err
	}
	receiptRevision := digest([]byte(value))
	if value == "bad-receipt" {
		receiptRevision = "missing"
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"format": "litheSettingsSourceEdit", "version": 0, "sourceID": req.SourceID,
		"revision": receiptRevision, "changed": true,
	})
}

func readSource(name string) (any, string, error) {
	data, err := os.ReadFile(name)
	if errors.Is(err, os.ErrNotExist) {
		return nil, "missing", nil
	}
	if err != nil {
		return nil, "", err
	}
	return string(data), digest(data), nil
}

func digest(data []byte) string { return fmt.Sprintf("sha256:%x", sha256.Sum256(data)) }
