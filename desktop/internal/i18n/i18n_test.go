package i18n

import (
	"fmt"
	"reflect"
	"testing"
)

// TestCatalogsAreComplete walks every catalog and fails on an empty string or a missing
// function, so a field added to Messages cannot ship untranslated.
func TestCatalogsAreComplete(t *testing.T) {
	for _, language := range Languages {
		checkComplete(t, language.Code(), reflect.ValueOf(*For(language)))
	}
}

func TestSharedSettingsFormatPreservesLanguageAndLiteralArguments(t *testing.T) {
	key := "desktop.settings.followSystemEffective"
	for _, test := range []struct {
		language Language
		value    string
		want     string
	}{
		{English, "Light", "Follow System (Light)"},
		{Chinese, "浅色", "跟随系统（浅色）"},
		{English, "{effective}", "Follow System ({effective})"},
	} {
		got := SharedFormat(test.language, key, map[string]string{"effective": test.value})
		if got != test.want || For(test.language).Settings.FollowSystem(test.value) != test.want {
			t.Fatalf("language %s: format = %q, want %q", test.language.Code(), got, test.want)
		}
	}
}

func TestSharedTemplateFormatsOnceAndPreservesUnknownPlaceholders(t *testing.T) {
	template := "{name} {value} {name} {missing}"
	got := formatSharedTemplate(template, map[string]string{"name": "{value}", "value": "$HOME"})
	if want := "{value} $HOME {value} {missing}"; got != want {
		t.Fatalf("formatted template = %q, want %q", got, want)
	}
}

func TestApplicationVersionUsesSharedLanguage(t *testing.T) {
	for _, test := range []struct {
		language Language
		version  string
		core     string
	}{
		{English, "Version 1.2.3", "Core 1.2.3"},
		{Chinese, "版本 1.2.3", "内核 1.2.3"},
	} {
		messages := For(test.language).App
		if messages.Name != "Lithe" || messages.DevBadge != "Dev" || messages.Version("1.2.3") != test.version || messages.Core("1.2.3") != test.core {
			t.Fatalf("language %s: application messages do not match the expected wording", test.language.Code())
		}
	}
}

func TestWelcomeLabelsUseSharedLanguage(t *testing.T) {
	for _, test := range []struct {
		language Language
		projects string
		open     string
		empty    string
	}{
		{English, "Projects", "Open", "No recent projects"},
		{Chinese, "项目", "打开", "没有最近项目"},
	} {
		welcome := For(test.language).Welcome
		if welcome.Projects != test.projects || welcome.Open != test.open || welcome.EmptyTitle != test.empty {
			t.Fatalf("language %s: welcome labels do not match the expected wording", test.language.Code())
		}
	}
}

func TestTitleLabelsUseSharedLanguage(t *testing.T) {
	for _, test := range []struct {
		language Language
		project  string
		open     string
		settings string
	}{
		{English, "Project menu", "Open Project…", "Settings…"},
		{Chinese, "项目菜单", "打开项目…", "设置…"},
	} {
		title := For(test.language).Title
		if title.ProjectMenu != test.project || title.OpenProject != test.open || title.Preferences != test.settings {
			t.Fatalf("language %s: title labels do not match the expected wording", test.language.Code())
		}
	}
}

func TestWorkbenchLabelsUseSharedLanguage(t *testing.T) {
	for _, test := range []struct {
		language Language
		project  string
		move     string
		resize   string
	}{
		{English, "Project", "Move to Left Top", "Resize"},
		{Chinese, "项目", "移到左侧上方", "调整大小"},
	} {
		messages := For(test.language)
		if messages.Tools.Project != test.project || messages.Dock.MoveLeftTop != test.move || messages.Panel.Resize != test.resize {
			t.Fatalf("language %s: workbench labels do not match the expected wording", test.language.Code())
		}
	}
}

func TestEditorAndProjectMessagesKeepUserContentLiteral(t *testing.T) {
	for _, test := range []struct {
		language Language
		open     string
		save     string
		read     string
	}{
		{English, "Could not open {reason}: {name}", "Could not save {reason}: {name}", "Could not read: {name}"},
		{Chinese, "无法打开 {reason}：{name}", "无法保存 {reason}：{name}", "读取失败：{name}"},
	} {
		messages := For(test.language)
		if messages.Editor.OpenFailed("{reason}", "{name}") != test.open || messages.Editor.SaveFailed("{reason}", "{name}") != test.save || messages.Project.Failed("{name}") != test.read {
			t.Fatalf("language %s: editor or project messages changed user content", test.language.Code())
		}
	}
}

func TestGitLabelsUseSharedLanguage(t *testing.T) {
	for _, test := range []struct {
		language Language
		branches string
		fetchAll string
		noCommit string
	}{
		{English, "Branches", "Fetch All Remotes", "No matching commits"},
		{Chinese, "分支", "获取所有远程", "没有匹配的提交"},
	} {
		git := For(test.language).Git
		if git.Branches != test.branches || git.FetchAll != test.fetchAll || git.NoMatches != test.noCommit {
			t.Fatalf("language %s: Git labels do not match the expected wording", test.language.Code())
		}
	}
}

func TestGitMessagesKeepFilterValuesLiteral(t *testing.T) {
	for _, test := range []struct {
		language Language
		filter   string
		failed   string
	}{
		{English, "{value}: {filter}", "Git read failed: {reason}"},
		{Chinese, "{value}：{filter}", "Git 读取失败：{reason}"},
	} {
		git := For(test.language).Git
		if git.FilterValue("{value}", "{filter}") != test.filter || git.Failed("{reason}") != test.failed {
			t.Fatalf("language %s: Git messages changed user content", test.language.Code())
		}
	}
}

func TestApplicationErrorsKeepReasonsLiteral(t *testing.T) {
	for _, test := range []struct {
		language Language
		message  string
	}{
		{English, "Could not open the settings window: {reason}"},
		{Chinese, "无法打开设置窗口：{reason}"},
	} {
		if got := For(test.language).Errors.SettingsFailed("{reason}"); got != test.message {
			t.Fatalf("language %s: error = %q, want %q", test.language.Code(), got, test.message)
		}
	}
}

func TestCommitBranchTerminalAndStatusLabelsUseSharedLanguage(t *testing.T) {
	for _, test := range []struct {
		language Language
		unstage  string
		branch   string
		terminal string
		changes  string
	}{
		{English, "Unstage all changes", "New Branch…", "New Terminal", "No changes"},
		{Chinese, "取消暂存所有更改", "新建分支…", "新建终端", "没有更改"},
	} {
		messages := For(test.language)
		if messages.Commit.UnstageAll != test.unstage || messages.Branch.NewBranch != test.branch || messages.Terminal.NewTab != test.terminal || messages.Status.NoChanges != test.changes {
			t.Fatalf("language %s: desktop labels do not match the expected wording", test.language.Code())
		}
	}
}

func TestTerminalAndStatusValuesPreserveExistingWording(t *testing.T) {
	for _, test := range []struct {
		language Language
		local    string
		second   string
		ended    string
		one      string
		many     string
	}{
		{English, "Local", "Local (2)", "Session ended with exit status -1.", "1 change", "2 changes"},
		{Chinese, "本地", "本地 (2)", "会话已结束，退出状态 -1。", "1 个更改", "2 个更改"},
	} {
		messages := For(test.language)
		if messages.Terminal.Tab(1) != test.local || messages.Terminal.Tab(2) != test.second || messages.Terminal.SessionEndedStatus(-1) != test.ended || messages.Status.Changes(1) != test.one || messages.Status.Changes(2) != test.many || messages.Status.MemoryValue(12) != "12 MB" || messages.Status.FPSValue(60) != "60 FPS" {
			t.Fatalf("language %s: terminal or status wording changed", test.language.Code())
		}
	}
}

func TestTerminalShellWordingUsesSharedLanguage(t *testing.T) {
	for _, test := range []struct {
		language Language
		menu     string
		noShells string
		withPath string
		auto     string
		missing  string
	}{
		{English, "New terminal with shell", "Shell not found", "bash (/opt/bin/bash)", "Automatic (zsh)", "/opt/bin/bash (not found)"},
		{Chinese, "使用 Shell 新建终端", "未找到 Shell", "bash (/opt/bin/bash)", "自动（zsh）", "/opt/bin/bash（未找到）"},
	} {
		messages := For(test.language)
		if messages.Terminal.ShellMenu != test.menu || messages.Terminal.NoShells != test.noShells || messages.Terminal.ShellWithPath("bash", "/opt/bin/bash") != test.withPath {
			t.Fatalf("language %s: terminal shell menu wording changed", test.language.Code())
		}
		if messages.Settings.NoShells != test.noShells || messages.Settings.ShellWithPath("bash", "/opt/bin/bash") != test.withPath || messages.Settings.TerminalShellAuto("zsh") != test.auto || messages.Settings.TerminalShellMissing("/opt/bin/bash") != test.missing {
			t.Fatalf("language %s: terminal settings wording changed", test.language.Code())
		}
	}
}

func TestCommitAndBranchMessagesKeepNamesLiteral(t *testing.T) {
	for _, test := range []struct {
		language Language
		publish  string
		exists   string
	}{
		{English, "Publish to {branch}/{remote}", "Branch name {name} already exists"},
		{Chinese, "发布到 {branch}/{remote}", "分支名称 {name} 已存在"},
	} {
		messages := For(test.language)
		if messages.Commit.PublishTo("{branch}", "{remote}") != test.publish || messages.Branch.NameExists("{name}") != test.exists {
			t.Fatalf("language %s: commit or branch messages changed user content", test.language.Code())
		}
	}
}

func TestCommitCountsAndStepPreserveExistingWording(t *testing.T) {
	for _, test := range []struct {
		language Language
		one      string
		many     string
		staged   string
		step     string
	}{
		{English, "1 file", "2 files", "2 staged", "1. {repository}: {action}"},
		{Chinese, "1 个文件", "2 个文件", "已暂存 2", "1. {repository}：{action}"},
	} {
		commit := For(test.language).Commit
		if commit.Files(1) != test.one || commit.Files(2) != test.many || commit.Staged(2) != test.staged || commit.Step(1, "{repository}", "{action}") != test.step {
			t.Fatalf("language %s: commit counts or step wording changed", test.language.Code())
		}
	}
}

func TestLogLabelsUseSharedLanguage(t *testing.T) {
	for _, test := range []struct {
		language Language
		filter   string
		session  string
		failure  string
	}{
		{English, "Invalid regular expression", "session: current", "Could not load logs. Try again."},
		{Chinese, "正则表达式无效", "会话：本次", "无法读取日志，请重试。"},
	} {
		logs := For(test.language).Logs
		if logs.Filter.InvalidRegex != test.filter || logs.SessionCurrent != test.session || logs.LoadFailed != test.failure {
			t.Fatalf("language %s: log labels do not match the expected wording", test.language.Code())
		}
	}
}

func TestLogMessagesPreserveCountsAndLiteralValues(t *testing.T) {
	for _, test := range []struct {
		language  Language
		filter    string
		operation string
	}{
		{English, "Filter error at 2–5: {start}", "Op {count} · 7 records · {op}"},
		{Chinese, "过滤错误，位置 2–5：{start}", "操作 {count} · 7 条 · 共 {op}"},
	} {
		logs := For(test.language).Logs
		if logs.FilterError(2, 5, "{start}") != test.filter || logs.Operation("{count}", 7, "{op}") != test.operation {
			t.Fatalf("language %s: log messages changed user content", test.language.Code())
		}
	}
}

func checkComplete(t *testing.T, path string, value reflect.Value) {
	t.Helper()
	switch value.Kind() {
	case reflect.Struct:
		for index := range value.NumField() {
			checkComplete(t, path+"."+value.Type().Field(index).Name, value.Field(index))
		}
	case reflect.String:
		if value.String() == "" {
			t.Errorf("%s is empty", path)
		}
	case reflect.Map:
		if value.Len() == 0 {
			t.Errorf("%s is empty", path)
		}
		for iter := value.MapRange(); iter.Next(); {
			checkComplete(t, fmt.Sprintf("%s[%v]", path, iter.Key()), iter.Value())
		}
	case reflect.Func:
		if value.IsNil() {
			t.Errorf("%s is nil", path)
			return
		}
		args := make([]reflect.Value, value.Type().NumIn())
		for index := range args {
			switch value.Type().In(index).Kind() {
			case reflect.String:
				args[index] = reflect.ValueOf("x")
			case reflect.Int:
				args[index] = reflect.ValueOf(2)
			default:
				t.Fatalf("%s takes an unsupported parameter type", path)
			}
		}
		if out := value.Call(args); out[0].String() == "" {
			t.Errorf("%s returns an empty string", path)
		}
	default:
		t.Fatalf("%s has unsupported kind %s", path, value.Kind())
	}
}

func TestDetect(t *testing.T) {
	cases := []struct {
		preferred []string
		want      Language
	}{
		{nil, English},
		{[]string{"zh-Hans-CN", "en-US"}, Chinese},
		{[]string{"en-GB", "zh-Hans"}, English},
		{[]string{"fr-FR", "zh-Hant-TW"}, Chinese},
		{[]string{"ZH"}, Chinese},
		{[]string{"fr", "de"}, English},
	}
	for _, c := range cases {
		if got := Detect(c.preferred); got != c.want {
			t.Errorf("Detect(%v) = %v, want %v", c.preferred, got, c.want)
		}
	}
}

func TestParseRoundTrips(t *testing.T) {
	for _, language := range Languages {
		got, ok := Parse(language.Code())
		if !ok || got != language {
			t.Errorf("Parse(%q) = %v, %v", language.Code(), got, ok)
		}
	}
	if _, ok := Parse(""); ok {
		t.Error("Parse accepts an empty code")
	}
	if _, ok := Parse("fr"); ok {
		t.Error("Parse accepts an unsupported code")
	}
}
