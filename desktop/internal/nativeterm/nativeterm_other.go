//go:build !darwin

package nativeterm

func read() (Colors, bool) { return Colors{}, false }
