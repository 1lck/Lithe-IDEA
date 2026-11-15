package term

import "testing"

func TestDirectoryReportObserverPreservesRepeatsAndChangeDeduplication(t *testing.T) {
	for _, stream := range []string{"\x1b]7;file:///same/directory\a", "\x1b]9;9;C:\\same\\directory\a"} {
		terminal := New(80, 24, 0)
		reports, changes := 0, 0
		terminal.SetCwdReport(func(Cwd) { reports++ })
		terminal.SetCwdChange(func(Cwd) { changes++ })
		terminal.Write([]byte(stream + stream))
		terminal.Write([]byte("\x1b]7;not-a-file-uri\a\x1b]9;9;relative\a"))
		if reports != 2 || changes != 1 {
			t.Fatalf("reports=%d, changes=%d; want 2 valid reports, 1 change", reports, changes)
		}
	}
}

func TestWindowsDirectoryReportsAreDataAndNotNotifications(t *testing.T) {
	terminal := New(80, 24, 0)
	var reports []Cwd
	notifications := 0
	terminal.SetNotify(func(Notification) { notifications++ })
	terminal.SetCwdChange(func(cwd Cwd) { reports = append(reports, cwd) })
	for _, path := range []string{`C:\Users\测试 空格;100%`, `D:\other`, `\\server\share\folder`} {
		terminal.Write([]byte("\x1b]9;9;" + path + "\x1b\\"))
		if cwd, ok := terminal.WorkingDirectory(); !ok || cwd.Path != path {
			t.Fatalf("report = %+v; want %q", cwd, path)
		}
	}
	terminal.Write([]byte("\x1b]9;9;\"C:\\quoted path\"\a"))
	if cwd, _ := terminal.WorkingDirectory(); cwd.Path != `C:\quoted path` {
		t.Fatalf("quoted path = %q", cwd.Path)
	}
	for _, value := range []string{"relative", "C:relative", "", "C:\\control\n", "\\"} {
		terminal.oscWindowsDirectory(value)
	}
	if len(reports) != 4 {
		t.Fatalf("invalid reports were accepted: %+v", reports)
	}
	if notifications != 0 {
		t.Fatal("a directory report produced a desktop notification")
	}
}
