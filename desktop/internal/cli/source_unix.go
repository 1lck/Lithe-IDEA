//go:build !windows

package cli

import (
	"context"
	"os"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
)

const launcherName = "lithe"

type nativeSource struct {
	shell, target, text string
	snapshot            configfile.Snapshot
	original            string
}

func readNativeSource(ctx context.Context) (nativeSource, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nativeSource{}, err
	}
	shell := filepath.Base(localshell.DefaultShell())
	var target string
	switch shell {
	case "zsh":
		root := os.Getenv("ZDOTDIR")
		if root == "" {
			root = home
		}
		target = filepath.Join(root, ".zshrc")
	case "bash":
		// Login bash reads the first existing profile. Interactive non-login shells
		// read .bashrc; the default login profile remains the registration source.
		target = filepath.Join(home, ".bash_profile")
		for _, name := range []string{".bash_profile", ".bash_login", ".profile"} {
			candidate := filepath.Join(home, name)
			_, err := os.Stat(candidate)
			if err == nil {
				target = candidate
				break
			}
			// log-exempt: 预期的缺失：bash 按顺序选择第一个存在的登录配置。
			if !os.IsNotExist(err) {
				return nativeSource{}, err
			}
		}
	case "sh":
		target = filepath.Join(home, ".profile")
	case "fish":
		root := os.Getenv("XDG_CONFIG_HOME")
		if root == "" {
			root = filepath.Join(home, ".config")
		}
		target = filepath.Join(root, "fish", "config.fish")
	default:
		return nativeSource{}, ErrUnsupportedShell
	}
	return captureSource(ctx, shell, target)
}

func captureSource(ctx context.Context, shell, target string) (nativeSource, error) {
	// Resolve an existing dotfile's symlink so dotfile managers keep their links.
	original := target
	resolved, err := filepath.EvalSymlinks(target)
	if err == nil {
		target = resolved
	} else if !os.IsNotExist(err) {
		return nativeSource{}, err
	}
	snapshot, err := configfile.Capture(ctx, filepath.Dir(target), filepath.Base(target), maximumSourceBytes)
	if err != nil {
		return nativeSource{}, err
	}
	text, err := snapshot.Text()
	if err != nil {
		return nativeSource{}, err
	}
	source := nativeSource{shell: shell, target: target, snapshot: snapshot, original: original}
	if text != nil {
		source.text = *text
	}
	return source, nil
}

func (s nativeSource) verify(ctx context.Context) error {
	resolved, err := filepath.EvalSymlinks(s.original)
	if os.IsNotExist(err) && s.original == s.target {
		return s.snapshot.Verify(ctx)
	}
	if err != nil {
		return err
	}
	if resolved != s.target {
		return configfile.ErrConflict
	}
	return s.snapshot.Verify(ctx)
}
func (s nativeSource) replace(ctx context.Context, text string) error {
	if text == s.text {
		return s.verify(ctx)
	}
	_, err := s.snapshot.Replace(ctx, []byte(text), func() error { return s.verify(ctx) })
	return err
}

func makeLauncherExecutable(path string) error { return os.Chmod(path, 0o700) }
func launcherExecutable(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().Perm()&0o100 != 0
}
