package keymapimport

import "os"

func openSelectedSource(path string) (*os.File, error) { return os.Open(path) }
