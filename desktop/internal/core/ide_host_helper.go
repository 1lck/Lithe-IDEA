package core

import "runtime"

// IDEHelperName is the file name of the packaged stdio helper binary: the lithe-ide-host
// crate's lithe-mcp bin. The desktop client embeds it and installs that name under its
// application-data directory; see internal/idehelp.
func IDEHelperName() string {
	if runtime.GOOS == "windows" {
		return "lithe-mcp.exe"
	}
	return "lithe-mcp"
}
