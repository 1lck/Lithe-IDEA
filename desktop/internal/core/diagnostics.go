package core

import "context"

// DiagnosticsEnvironment is what the client knows about the machine a diagnostic bundle comes
// from. The client gathers it; the kernel never reads the system itself.
type DiagnosticsEnvironment struct {
	AppVersion     string `json:"appVersion"`
	OsName         string `json:"osName"`
	OsVersion      string `json:"osVersion"`
	CpuCoreCount   uint32 `json:"cpuCoreCount"`
	MemoryRssBytes uint64 `json:"memoryRssBytes"`
	DiskFreeBytes  uint64 `json:"diskFreeBytes"`
}

// DiagnosticsFile is one file of a diagnostic bundle, already redacted and staged.
type DiagnosticsFile struct {
	// RelativePath is the file's path in the bundle, with / between its parts.
	RelativePath string `json:"relativePath"`
	SizeBytes    uint64 `json:"sizeBytes"`
	// Description is what the export dialog may say the file holds.
	Description string `json:"description"`
}

// DiagnosticsManifest is the manifest.json of a diagnostic bundle. The kernel sorts its files
// by path, so the same bundle always has the same manifest.
type DiagnosticsManifest struct {
	// Redaction names the redaction the bundle's files went through.
	Redaction                    string                 `json:"redaction"`
	SchemaVersion                int                    `json:"schemaVersion"`
	GeneratedAtEpochMilliseconds int64                  `json:"generatedAtEpochMilliseconds"`
	Environment                  DiagnosticsEnvironment `json:"environment"`
	Files                        []DiagnosticsFile      `json:"files"`
}

type redactTextRequest struct {
	Text string `json:"text"`
}

type redactTextResult struct {
	Redacted string `json:"redacted"`
}

// RedactText is text with what the kernel redacts in logs (paths, URLs, tokens, user content)
// replaced by its marker.
func (c *Client) RedactText(ctx context.Context, text string) (string, error) {
	var result redactTextResult
	if err := c.Execute(ctx, "diagnostics.redactText", redactTextRequest{Text: text}, &result); err != nil {
		return "", err
	}
	return result.Redacted, nil
}

type buildManifestRequest struct {
	Environment                  DiagnosticsEnvironment `json:"environment"`
	Files                        []DiagnosticsFile      `json:"files"`
	GeneratedAtEpochMilliseconds int64                  `json:"generatedAtEpochMilliseconds"`
}

// BuildDiagnosticsManifest shapes the manifest of a bundle of files, generated at generatedAt
// milliseconds since the epoch.
func (c *Client) BuildDiagnosticsManifest(ctx context.Context, environment DiagnosticsEnvironment, files []DiagnosticsFile, generatedAt int64) (DiagnosticsManifest, error) {
	var manifest DiagnosticsManifest
	request := buildManifestRequest{Environment: environment, Files: nonNil(files), GeneratedAtEpochMilliseconds: generatedAt}
	if err := c.Execute(ctx, "diagnostics.buildManifest", request, &manifest); err != nil {
		return DiagnosticsManifest{}, err
	}
	manifest.Files = nonNil(manifest.Files)
	return manifest, nil
}
