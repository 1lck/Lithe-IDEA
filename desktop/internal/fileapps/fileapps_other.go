//go:build !darwin && !windows

package fileapps

import "errors"

// Other systems have no association database this package reads, so they offer no
// application and the caller keeps only its application picker.
func list(string) ([]App, error) { return nil, nil }

func open(string, App) error { return errors.ErrUnsupported }
