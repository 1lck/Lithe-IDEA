package i18n

import "testing"

// These count-bearing English notices must read correctly both for one item and
// for multiple items, without introducing a second plural-selection rule in Go.
func TestCountNoticesUseNumberNeutralEnglish(t *testing.T) {
	tests := []struct {
		name, key string
		values    map[string]string
		want      string
	}{
		{"one search match", "desktop.search.count", map[string]string{"count": "1", "files": "1"}, "Matches: 1 · Files: 1"},
		{"multiple search matches", "desktop.search.count", map[string]string{"count": "2", "files": "3"}, "Matches: 2 · Files: 3"},
		{"one loaded match", "desktop.search.loadedCount", map[string]string{"count": "1", "files": "1"}, "Loaded matches: 1 · Files: 1"},
		{"multiple loaded matches", "desktop.search.loadedCount", map[string]string{"count": "3", "files": "2"}, "Loaded matches: 3 · Files: 2"},
		{"one failed forward", "desktop.remote.ports.restoreFailed", map[string]string{"count": "1"}, "Forwards not restored after reconnecting: 1. See the affected rows for details."},
		{"multiple failed forwards", "desktop.remote.ports.restoreFailed", map[string]string{"count": "2"}, "Forwards not restored after reconnecting: 2. See the affected rows for details."},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := SharedFormat(English, test.key, test.values); got != test.want {
				t.Fatalf("format %s: got %q, want %q", test.key, got, test.want)
			}
		})
	}
}

func TestNumberNeutralEnglishKeepsExistingChineseTranslations(t *testing.T) {
	for _, tc := range []struct {
		key    string
		values map[string]string
		want   string
	}{
		{"desktop.search.count", map[string]string{"count": "1", "files": "1"}, "1 个文件中有 1 行匹配"},
		{"desktop.search.loadedCount", map[string]string{"count": "1", "files": "1"}, "已加载 1 个文件的 1 行匹配"},
		{"desktop.remote.ports.restoreFailed", map[string]string{"count": "1"}, "重新连接后有 1 个转发无法恢复，原因见对应行。"},
	} {
		if got := SharedFormat(Chinese, tc.key, tc.values); got != tc.want {
			t.Fatalf("Chinese %s: got %q, want %q", tc.key, got, tc.want)
		}
	}
}
