//go:build !darwin && !windows

package fileassociations

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

type nativeState struct{}

func readNative(ctx context.Context, formats []core.FileAssociationFormat) (State, error) {
	state := State{Formats: formats}
	for _, format := range formats {
		state.Handlers = append(state.Handlers, Handler{Extension: format.Extension})
	}
	return state, ctx.Err()
}

func applyNative(context.Context, nativeState, []string, string) error { return ErrUnsupported }
