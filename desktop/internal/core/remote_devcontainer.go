package core

import (
	"bytes"
	"context"
	"encoding/json"
)

// DevcontainerConfig is one devcontainer.json remote.devcontainerConfigs found in a folder.
type DevcontainerConfig struct {
	// Path is relative to the folder with / separators, such as .devcontainer/devcontainer.json.
	Path string `json:"path"`
	// Name is the configuration's name, at most 128 bytes without control characters; empty when
	// it has none. It is the folder's text: shown as it is and never logged.
	Name string `json:"name,omitempty"`
}

// RemoteDevcontainerConfigs lists the devcontainer.json files of folder, an absolute folder on this
// machine, in the order the Dev Container specification searches them. Listing starts nothing. A
// relative folder is CodeInvalidRequest and one that is not a directory CodeWorkspaceNotFound.
func (c *Client) RemoteDevcontainerConfigs(ctx context.Context, folder string) ([]DevcontainerConfig, error) {
	var result struct {
		Configs []DevcontainerConfig `json:"configs"`
	}
	request := struct {
		Folder string `json:"folder"`
	}{Folder: folder}
	if err := c.Execute(ctx, "remote.devcontainerConfigs", request, &result); err != nil {
		return nil, err
	}
	return nonNil(result.Configs), nil
}

// DevcontainerUpRequest asks remote.devcontainerUp to build or reuse and start a folder's dev
// container.
type DevcontainerUpRequest struct {
	// Folder is the absolute folder on this machine.
	Folder string `json:"folder"`
	// Config is one of the paths RemoteDevcontainerConfigs listed; empty lets the CLI search.
	Config string `json:"config,omitempty"`
	// Engine is ContainerEngineDocker or ContainerEnginePodman.
	Engine string `json:"engine"`
	// ProjectCodeAllowed is the folder's trust decision. Building runs the folder's code on this
	// machine, so without it Core runs nothing (CodeDevcontainerUntrustedFolder).
	ProjectCodeAllowed bool `json:"projectCodeAllowed"`
}

// Devcontainer is the running container remote.devcontainerUp started and the folder to open in it.
type Devcontainer struct {
	Engine string `json:"engine"`
	// Container is the container's name, or its id when the engine reports no name.
	Container   string `json:"container"`
	ContainerID string `json:"containerId"`
	// User is the configuration's remoteUser; empty is the image's default user.
	User string `json:"user,omitempty"`
	// WorkspaceFolder is the absolute folder inside the container to open.
	WorkspaceFolder string `json:"workspaceFolder"`
}

// Connection is the container as remote.connect's container field names it.
func (d Devcontainer) Connection() ContainerConnection {
	return ContainerConnection{Engine: d.Engine, Container: d.Container, User: d.User}
}

// DevcontainerUp is what remote.devcontainerUp reported.
type DevcontainerUp struct {
	// Container is nil when the CLI reported a failure.
	Container *Devcontainer `json:"container,omitempty"`
	// Diagnostics is the end of the CLI's log and its error, redacted, when it failed. It is
	// upstream text: shown as it is and never logged.
	Diagnostics string `json:"diagnostics"`
}

// DevcontainerOutput is one devcontainerOutput event: a redacted line of the CLI's log, or the note
// that later lines were dropped. It is upstream text: shown as it is and never logged.
type DevcontainerOutput struct {
	Text      string `json:"text"`
	Truncated bool   `json:"truncated"`
}

// devcontainerOutputEvent marks the execution events that carry the CLI's log.
var devcontainerOutputEvent = []byte(`"devcontainerOutput"`)

// RemoteDevcontainerUp runs the Dev Container CLI's up for request, at most an hour and cancelled
// with ctx, and hands each line of its log to output on the request's goroutine; output must
// return promptly. A missing CLI is CodeRuntimeMissing, an untrusted folder
// CodeDevcontainerUntrustedFolder, a config the folder does not list CodeInvalidRequest and a
// result Lithe cannot enter CodeParseFailed.
func (c *Client) RemoteDevcontainerUp(ctx context.Context, request DevcontainerUpRequest, output func(DevcontainerOutput)) (DevcontainerUp, error) {
	var result DevcontainerUp
	if _, err := c.ExecuteWithEvents(ctx, "remote.devcontainerUp", request, &result, devcontainerOutputObserver(output)); err != nil {
		return DevcontainerUp{}, err
	}
	return result, nil
}

// devcontainerOutputObserver hands output the devcontainerOutput events among an operation's
// execution events and skips the rest; a nil output observes nothing.
func devcontainerOutputObserver(output func(DevcontainerOutput)) func(json.RawMessage) {
	if output == nil {
		return nil
	}
	return func(raw json.RawMessage) {
		if !bytes.Contains(raw, devcontainerOutputEvent) {
			return
		}
		var event struct {
			Type      string `json:"type"`
			Text      string `json:"text"`
			Truncated bool   `json:"truncated"`
		}
		if json.Unmarshal(raw, &event) == nil && event.Type == "devcontainerOutput" {
			output(DevcontainerOutput{Text: event.Text, Truncated: event.Truncated})
		}
	}
}
