package workbench

import (
	"context"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// The General page's local history card reads the open project's history through
// localHistorySettings: Core checks the rules being edited (history.ignorePreview), measures
// the project's snapshots against the limit (history.usage) and deletes them
// (history.clear). The snapshots live in the client's data directory
// (localHistoryDirectory), never the project or the installed application; the settings
// themselves are stored with the rest of the preferences and reach Core with every record
// (localHistoryJob).

// localHistorySettings is the open project's local history as the settings window reaches it,
// off the window thread.
type localHistorySettings struct {
	app    *App
	kernel localHistoryKernel
}

// localHistorySettingsSource is the settings window's view of local history, or nil when the
// kernel keeps none.
func (a *App) localHistorySettingsSource() settingswindow.LocalHistorySource {
	kernel, ok := a.kernel.(localHistoryKernel)
	if !ok {
		return nil
	}
	return localHistorySettings{app: a, kernel: kernel}
}

// project is the open project's root and the folder of its snapshots; ok is false when no
// project is open or the client has no data directory.
func (s localHistorySettings) project() (root, storage string, ok bool) {
	current := s.app.toolchainRoot.Load()
	if current == nil {
		return "", "", false
	}
	storage, ok = s.app.localHistoryDirectory(*current)
	return *current, storage, ok
}

// Preview has Core check rules and, for a path, which of them keeps it out of the open
// project's history; Core says whether Git ignores the path only for an open project.
func (s localHistorySettings) Preview(ctx context.Context, rules core.HistoryIgnoreRules, path string) (core.HistoryIgnorePreview, error) {
	root, _, _ := s.project()
	preview, err := s.kernel.PreviewHistoryIgnore(ctx, rules, root, path)
	// log-exempt: 随输入实时重算的校验提示：测试路径越出项目时 Core 拒绝请求，卡片随键入提示，不是系统失败。
	var refused *core.Error
	if !errors.As(err, &refused) || refused.Code != core.CodeInvalidRequest {
		s.logFailure("local_history_preview", err)
	}
	return preview, err
}

// Usage measures the open project's history and the limit Core keeps it under.
func (s localHistorySettings) Usage(ctx context.Context, limitMegabytes int) (core.HistoryUsage, bool, error) {
	_, storage, ok := s.project()
	if !ok {
		return core.HistoryUsage{}, false, nil
	}
	limit := settingswindow.LocalHistorySettings{LimitMegabytes: limitMegabytes}.Policy().StorageLimitBytes
	usage, err := s.kernel.LocalHistoryUsage(ctx, storage, limit)
	s.logFailure("local_history_usage", err)
	return usage, true, err
}

// Clear deletes the open project's snapshots. With no project open there is nothing to delete.
func (s localHistorySettings) Clear(ctx context.Context) error {
	_, storage, ok := s.project()
	if !ok {
		return nil
	}
	err := s.kernel.ClearHistory(ctx, storage)
	s.logFailure("local_history_clear", err)
	return err
}

// logFailure records a failed local history request. The settings window gave up on it when
// its context ended, which is not a failure.
func (s localHistorySettings) logFailure(operation string, err error) {
	// log-exempt: 用户取消：设置窗口关闭或放弃了这次请求。
	if err == nil || errors.Is(err, context.Canceled) {
		return
	}
	s.app.emit(operationFailedLevel, operationFailedEvent, operationFailedFields(operation, err))
}
