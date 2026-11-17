package conpty

import _ "embed"

var (
	//go:embed win-arm64/conpty.dll
	arm64DLL []byte
	//go:embed arm64/OpenConsole.exe
	arm64Host []byte
	//go:embed LICENSE.txt
	license []byte
)

// bundled is the arm64 client's set; an arm64 program only runs on an arm64 kernel. The
// license travels with the installed copy.
var bundled = []file{
	{path: "LICENSE.txt", data: license},
	{path: DLL, data: arm64DLL},
	{path: "arm64/OpenConsole.exe", data: arm64Host},
}
