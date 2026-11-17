package pluginsettings

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// ErrSourcesCommitted means a source was published before a later failure.
// The editor must retain its draft and require a fresh read before retrying.
var ErrSourcesCommitted = errors.New("native settings sources were published; reload before retrying")

type SourceKernel interface {
	PlanSourceSettingsEdits(context.Context, core.SourceSettingsSnapshot, []core.SourceSettingsEdits, bool) ([]core.SourceSettingsWrite, error)
	DecodeSourceSettingsReceipt(context.Context, core.SourceSettingsWrite, json.RawMessage) (core.SourceSettingsReceipt, error)
}

// SourceEditor exposes only Core's non-sensitive projection. Native source
// bytes and read identities are private, as in the preference Snapshot.
type SourceEditor struct {
	State          core.SourceSettingsState
	root           string
	files          map[string]configfile.Snapshot
	paths          map[string]string
	limits         core.SourceSettingsLimits
	protectedRoots []string
}

func sourceRevision(file configfile.Snapshot) string {
	if !file.Exists() {
		return "missing"
	}
	digest := sha256.Sum256(file.Bytes())
	return "sha256:" + hex.EncodeToString(digest[:])
}

// CaptureSources is read-only. Package/installation roots come from the native
// owner, not a plugin's projection; native aliases are rejected before editing.
func CaptureSources(ctx context.Context, workspace string, state core.SourceSettingsState, protectedRoots []string) (SourceEditor, error) {
	editor := SourceEditor{State: state, root: workspace, limits: state.Limits, files: make(map[string]configfile.Snapshot), paths: make(map[string]string), protectedRoots: append([]string(nil), protectedRoots...)}
	if editor.limits.MaximumSourceBytes <= 0 || editor.limits.MaximumTotalBytes <= 0 {
		return editor, configfile.ErrTooLarge
	}
	var bytes int64
	var identities []os.FileInfo
	for _, source := range state.Snapshot.Sources {
		if err := ctx.Err(); err != nil {
			return editor, err
		}
		file, err := configfile.Capture(ctx, workspace, source.Path, editor.limits.MaximumSourceBytes)
		if err != nil {
			return editor, err
		}
		if sourceRevision(file) != source.Revision {
			return editor, configfile.ErrConflict
		}
		if err := allowSourcePath(file.Path(), protectedRoots); err != nil {
			return editor, err
		}
		if file.Exists() {
			info, err := os.Stat(file.Path())
			if err != nil {
				return editor, err
			}
			for _, previous := range identities {
				if os.SameFile(previous, info) {
					return editor, configfile.ErrTarget
				}
			}
			identities = append(identities, info)
		}
		bytes += int64(len(file.Bytes()))
		if bytes > editor.limits.MaximumTotalBytes {
			return editor, configfile.ErrTooLarge
		}
		editor.files[source.ID], editor.paths[source.ID] = file, source.Path
	}
	return editor, nil
}

// Resolve the nearest existing parent as well as the leaf, so missing files
// under an installed bundle cannot bypass the read-only ownership boundary.
func allowSourcePath(path string, roots []string) error {
	canonical := path
	var tail []string
	for {
		resolved, err := filepath.EvalSymlinks(canonical)
		if err == nil {
			canonical = resolved
			break
		}
		if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		parent := filepath.Dir(canonical)
		if parent == canonical {
			return configfile.ErrTarget
		}
		tail = append(tail, filepath.Base(canonical))
		canonical = parent
	}
	for index := len(tail) - 1; index >= 0; index-- {
		canonical = filepath.Join(canonical, tail[index])
	}
	for _, root := range roots {
		if root == "" {
			continue
		}
		resolved, err := filepath.EvalSymlinks(root)
		// log-exempt: 预期的缺失：尚未创建的插件安装根不含发行资源。
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(resolved, canonical)
		if err == nil && (relative == "." || filepath.IsLocal(relative)) {
			return configfile.ErrTarget
		}
	}
	return nil
}

type stagedSource struct {
	write    core.SourceSettingsWrite
	before   configfile.Snapshot
	content  []byte
	revision string
}

// Apply prepares every replacement before publishing any source. Each commit
// retains the captured bytes and metadata guard. A partial failure is explicit.
// The caller owns workspace/package checks and must perform a fresh read-back.
func (s SourceEditor) Apply(ctx context.Context, kernel SourceKernel, edits []core.SourceSettingsEdits, call func(context.Context, json.RawMessage) (json.RawMessage, error), check func() error) (published map[string]string, err error) {
	published = make(map[string]string)
	defer func() {
		if err != nil && len(published) > 0 {
			err = errors.Join(ErrSourcesCommitted, err)
		}
	}()
	writes, err := kernel.PlanSourceSettingsEdits(ctx, s.State.Snapshot, edits, true)
	if err != nil || len(writes) == 0 {
		return published, err
	}
	if err := check(); err != nil {
		return published, err
	}
	staging, err := os.MkdirTemp("", "lithe-source-settings-")
	if err != nil {
		return published, err
	}
	defer func() { err = errors.Join(err, os.RemoveAll(staging)) }()
	var staged []stagedSource
	var total int64
	for _, write := range writes {
		before, ok := s.files[write.SourceID]
		if !ok || write.Path != s.paths[write.SourceID] || sourceRevision(before) != write.Revision {
			return published, configfile.ErrConflict
		}
		if err := before.Verify(ctx); err != nil {
			return published, err
		}
		if err := check(); err != nil {
			return published, err
		}
		file, err := os.CreateTemp(staging, "source-*")
		if err != nil {
			return published, err
		}
		name := file.Name()
		if err := file.Close(); err != nil {
			return published, err
		}
		params, err := json.Marshal(struct {
			Operation  string                     `json:"operation"`
			SourceID   string                     `json:"sourceID"`
			Revision   string                     `json:"revision"`
			Values     map[string]json.RawMessage `json:"values"`
			OutputFile string                     `json:"outputFile"`
		}{"editSource", write.SourceID, write.Revision, write.Values, name})
		if err != nil {
			return published, err
		}
		result, err := call(ctx, params)
		if err != nil {
			return published, err
		}
		receipt, err := kernel.DecodeSourceSettingsReceipt(ctx, write, result)
		if err != nil {
			return published, err
		}
		if !receipt.Changed {
			continue
		}
		stagedFile, err := configfile.Capture(ctx, staging, filepath.Base(name), s.limits.MaximumSourceBytes)
		if err != nil {
			return published, err
		}
		if sourceRevision(stagedFile) != receipt.Revision {
			return published, configfile.ErrConflict
		}
		content := stagedFile.Bytes()
		total += int64(len(content))
		if total > s.limits.MaximumTotalBytes {
			return published, configfile.ErrTooLarge
		}
		staged = append(staged, stagedSource{write: write, before: before, content: content, revision: receipt.Revision})
	}
	current := make([]configfile.Snapshot, len(staged))
	for index := range staged {
		current[index] = staged[index].before
	}
	verify := func() error {
		if err := check(); err != nil {
			return err
		}
		for _, file := range current {
			if err := allowSourcePath(file.Path(), s.protectedRoots); err != nil {
				return err
			}
			if err := file.Verify(ctx); err != nil {
				return err
			}
		}
		return nil
	}
	for index, replacement := range staged {
		committed, err := replacement.before.Replace(ctx, replacement.content, verify)
		if committed {
			published[replacement.write.SourceID] = replacement.revision
		}
		if err != nil {
			return published, err
		}
		current[index], err = configfile.Capture(ctx, s.root, replacement.write.Path, s.limits.MaximumSourceBytes)
		if err != nil {
			return published, err
		}
		if sourceRevision(current[index]) != replacement.revision {
			return published, configfile.ErrConflict
		}
	}
	return published, nil
}
