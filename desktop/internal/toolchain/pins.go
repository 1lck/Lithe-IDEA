package toolchain

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// ErrPinCommitted requires a fresh load before retrying a draft: publication
// completed, but a later cleanup or readback did not establish a new baseline.
var ErrPinCommitted = errors.New("toolchain: pin document committed; reload its source before retrying")

type pinSource struct {
	file     configfile.Snapshot
	plan     core.ToolchainPinStoragePlan
	document json.RawMessage
}

func capturePinSource(ctx context.Context, kernel Kernel, root string) (pinSource, error) {
	plan, err := kernel.ToolchainPinStorage(ctx)
	if err != nil {
		return pinSource{}, err
	}
	file, err := configfile.Capture(ctx, root, plan.DocumentRelativePath, plan.MaximumDocumentBytes)
	if err != nil {
		return pinSource{}, pinSourceError(err)
	}
	text, err := file.Text()
	if err != nil {
		return pinSource{}, err
	}
	document, err := kernel.DecodeToolchainPinDocument(ctx, text)
	if err != nil {
		return pinSource{}, err
	}
	return pinSource{file: file, plan: plan, document: document}, nil
}

func pinSourceError(err error) error {
	if errors.Is(err, configfile.ErrConflict) {
		return errors.Join(ErrPinConflict, err)
	}
	return err
}

// SavePin replaces exactly one pin, preserving other Core-accepted entries.
func SavePin(ctx context.Context, kernel Kernel, root, directory, tool string, pin *core.ToolchainPin, baseline []byte) (json.RawMessage, []byte, error) {
	return SavePins(ctx, kernel, root, directory, []Edit{{Tool: tool, Pin: pin}}, baseline)
}

// SavePins captures a bounded source, checks the caller's byte baseline, then
// conditionally publishes Core's edit. Settings drafts use Snapshot.SavePins to
// bind the source and native workspace identity captured during their load.
func SavePins(ctx context.Context, kernel Kernel, root, directory string, edits []Edit, baseline []byte) (json.RawMessage, []byte, error) {
	identity, err := directoryIdentity(ctx, root)
	if err != nil {
		return nil, nil, err
	}
	source, err := capturePinSource(ctx, kernel, root)
	if err != nil {
		return nil, nil, err
	}
	if source.file.Exists() != (baseline != nil) || !bytes.Equal(source.file.Bytes(), baseline) {
		return nil, nil, ErrPinConflict
	}
	return savePins(ctx, kernel, root, directory, edits, source, func() error { return checkDirectoryIdentity(ctx, root, identity) })
}

// SavePins binds an explicit draft to its private captured source, not the
// exported display bytes which a caller may have changed.
func (s Snapshot) SavePins(ctx context.Context, kernel Kernel, edits []Edit) (json.RawMessage, []byte, error) {
	return savePins(ctx, kernel, s.Root, s.Directory, edits, s.source, func() error { return checkDirectoryIdentity(ctx, s.Root, s.rootIdentity) })
}

func savePins(ctx context.Context, kernel Kernel, root, directory string, edits []Edit, source pinSource, checkRoot func() error) (json.RawMessage, []byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	check := func() error {
		if err := checkRoot(); err != nil {
			return err
		}
		return pinSourceError(source.file.Verify(ctx))
	}
	if err := check(); err != nil {
		return nil, nil, err
	}
	ignore, err := configfile.Capture(ctx, root, source.plan.IgnoreRelativePath, source.plan.MaximumIgnoreBytes)
	if err != nil {
		return nil, nil, pinSourceError(err)
	}
	documentText, err := source.file.Text()
	if err != nil {
		return nil, nil, err
	}
	ignoreText, err := ignore.Text()
	if err != nil {
		return nil, nil, err
	}
	edit, err := kernel.EditToolchainPinSources(ctx, core.ToolchainPinSourcesRequest{Document: documentText, IgnoreDocument: ignoreText, Directory: directory, Edits: edits})
	if err != nil {
		return nil, nil, err
	}
	// A no-op still rejects edits made while Core was computing its response.
	if err := check(); err != nil {
		return nil, nil, err
	}
	if err := ignore.Verify(ctx); err != nil {
		return nil, nil, pinSourceError(err)
	}
	if !edit.DocumentChanged {
		return append(json.RawMessage(nil), source.document...), source.file.Bytes(), nil
	}
	if edit.Document == nil {
		return nil, nil, fmt.Errorf("toolchain: Core returned a changed document without content")
	}
	// The ignore prerequisite can safely remain if the later pin publication
	// fails. Never report a partially committed pin as an untouched draft.
	if edit.IgnoreChanged {
		if edit.IgnoreDocument == nil {
			return nil, nil, fmt.Errorf("toolchain: Core returned a changed ignore source without content")
		}
		if _, err := ignore.Replace(ctx, []byte(*edit.IgnoreDocument), check); err != nil {
			return nil, nil, fmt.Errorf("toolchain: ignore prerequisite: %w", pinSourceError(err))
		}
	}
	committed, err := source.file.Replace(ctx, []byte(*edit.Document), checkRoot)
	if err != nil {
		if committed {
			err = errors.Join(ErrPinCommitted, err)
		}
		return nil, nil, pinSourceError(err)
	}
	// Successful publication returns the Core-validated document and new bytes.
	encoded := []byte(*edit.Document)
	return json.RawMessage(encoded), encoded, nil
}
