//go:build windows

package localshell

import (
	"encoding/base64"
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf16"
)

// Windows Terminal's OSC 9;9 carries a native path without URI escaping. Wrap
// the existing prompt, only for recognized interactive shells. Never write a
// startup command into a running terminal or modify a profile on disk.
func integrateWindowsShell(config Config, program string) Config {
	token := config.DirectoryToken
	if token == "" || len(token) > 128 || len(config.Args) != 0 || strings.IndexFunc(token, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_')
	}) >= 0 {
		return config
	}
	switch strings.ToLower(filepath.Base(program)) {
	case "pwsh.exe", "powershell.exe":
		script := strings.ReplaceAll(powerShellDirectoryIntegration, "__MOTTY_TOKEN__", token)
		config.Args = []string{"-NoLogo", "-NoExit", "-EncodedCommand", encodePowerShellCommand(script)}
	case "cmd.exe":
		prompt := os.Getenv("PROMPT")
		for _, entry := range config.Env {
			if key, value, ok := strings.Cut(entry, "="); ok && strings.EqualFold(key, "PROMPT") {
				prompt = value
			}
		}
		if prompt == "" {
			prompt = "$P$G"
		}
		// Pass an environment value, never a /K command: special path/prompt
		// characters must not become executable CMD syntax.
		prefix := "$e]133;A;motty=" + token + "$e\\$e]9;9;$P$e\\"
		config.Env = append(append([]string(nil), config.Env...), "PROMPT="+prefix+prompt+"$e]133;B;motty="+token+"$e\\")
	}
	return config
}

func encodePowerShellCommand(script string) string {
	units := utf16.Encode([]rune(script))
	encoded := make([]byte, len(units)*2)
	for i, unit := range units {
		binary.LittleEndian.PutUint16(encoded[i*2:], unit)
	}
	return base64.StdEncoding.EncodeToString(encoded)
}

const powerShellDirectoryIntegration = `
if ($ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage') {
    $global:__MottyOriginalPrompt = $function:prompt
    function global:prompt {
        $failed = -not $global:?
        # Preserve the previous failure state for custom prompts. Ignore avoids
        # adding a synthetic entry to $Error; LASTEXITCODE is never assigned.
        if ($failed) { Write-Error 'motty-prompt-status' -ErrorAction Ignore }
        $original = $global:__MottyOriginalPrompt.Invoke()
        $esc = [char]27
        $report = "$esc]133;A;motty=__MOTTY_TOKEN__$([char]7)"
        if ($pwd.Provider.Name -eq 'FileSystem') {
            $report += "$esc]9;9;$($pwd.ProviderPath)$([char]7)"
        }
        return "$report$original$esc]133;B;motty=__MOTTY_TOKEN__$([char]7)"
    }
}
`
