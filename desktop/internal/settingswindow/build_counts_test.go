package settingswindow

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// TestBuildCountsUseTheSingularForOne checks the build settings texts that count
// pages, debuggers and tools: English says "1 page", not "1 pages", and other
// counts keep the plural with grouped digits.
func TestBuildCountsUseTheSingularForOne(t *testing.T) {
	for _, test := range []struct {
		name string
		got  string
		want string
	}{
		{"one page", kindPageCount(i18n.English, 1), "1 page"},
		{"pages", kindPageCount(i18n.English, 1200), "1,200 pages"},
		{"no pages", kindPageCount(i18n.English, 0), "0 pages"},
		{"one debugger", debuggerCount(i18n.English, 1), "1 debugger"},
		{"debuggers", debuggerCount(i18n.English, 3), "3 debuggers"},
		{"one stepping debugger", steppingTileDescription(i18n.English, 1, 0), "Stepping: 1 debugger supports filters"},
		{"one customized stepping debugger", steppingTileDescription(i18n.English, 1, 1), "Stepping: 1 debugger supports filters · customized"},
		{"stepping debuggers", steppingTileDescription(i18n.English, 2, 0), "Stepping: 2 debuggers support filters"},
		{"customized stepping debuggers", steppingTileDescription(i18n.English, 2, 1), "Stepping: 2 debuggers support filters · 1 customized"},
		{"one tool in the project", trustBannerText(i18n.English, 1, ".venv"), "1 tool comes from an environment inside the project (.venv). Lithe does not probe or run it until you trust the project."},
		{"tools in the project", trustBannerText(i18n.English, 2, ".venv, .conda"), "2 tools come from environments inside the project (.venv, .conda). Lithe does not probe or run them until you trust the project."},
		{"one issue", issuesTitle(i18n.English, 1), "1 needs attention"},
		{"issues", issuesTitle(i18n.English, 2), "2 need attention"},
		{"one tool from one plugin", toolchainsTileDescription(i18n.English, 1, 1, "global"), "1 tool · from 1 plugin · showing global"},
		{"one tool from plugins", toolchainsTileDescription(i18n.English, 1, 2, "global"), "1 tool · from 2 plugins · showing global"},
		{"tools from one plugin", toolchainsTileDescription(i18n.English, 4, 1, "global"), "4 tools · from 1 plugin · showing global"},
		{"tools from plugins", toolchainsTileDescription(i18n.English, 4, 2, "global"), "4 tools · from 2 plugins · showing global"},
		{"one tool listed", toolchainListCount(i18n.English, 1, 1), "1 / 1 tool"},
		{"tools listed", toolchainListCount(i18n.English, 1, 3), "1 / 3 tools"},
		{"one page in Chinese", kindPageCount(i18n.Chinese, 1), "1 个页面"},
		{"one tool from one plugin in Chinese", toolchainsTileDescription(i18n.Chinese, 1, 1, "全局"), "1 个工具 · 来自 1 个插件 · 当前显示全局"},
		{"one tool in Chinese", trustBannerText(i18n.Chinese, 1, ".venv"), "1 个工具来自项目内的环境（.venv）。信任项目之前不会探测或运行它。"},
	} {
		if test.got != test.want {
			t.Errorf("%s = %q, want %q", test.name, test.got, test.want)
		}
	}
}
