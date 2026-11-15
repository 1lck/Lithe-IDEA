package conpty

import _ "embed"

var (
	//go:embed win-x64/conpty.dll
	x64DLL []byte
	//go:embed x64/OpenConsole.exe
	x64Host []byte
	//go:embed arm64/OpenConsole.exe
	arm64Host []byte
	//go:embed LICENSE.txt
	license []byte
)

// bundled is the x64 client's set. The console host follows the kernel, not the program, so
// the set carries both: x64 Lithe also runs, emulated, on Windows on ARM. The license
// travels with the installed copy.
var bundled = []file{
	{path: "LICENSE.txt", data: license},
	{path: DLL, data: x64DLL},
	{path: "x64/OpenConsole.exe", data: x64Host},
	{path: "arm64/OpenConsole.exe", data: arm64Host},
}
