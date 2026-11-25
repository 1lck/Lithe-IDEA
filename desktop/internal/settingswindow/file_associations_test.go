package settingswindow

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/fileassociations"
)

func TestFileAssociationsCancellationKeepsFailures(t *testing.T) {
	for _, test := range []struct {
		name string
		err  error
		want bool
	}{
		{"cancelled", context.Canceled, true},
		{"wrapped cancellation", fmt.Errorf("read: %w", context.Canceled), true},
		{"cancelled causes", errors.Join(context.Canceled, context.Canceled), true},
		{"consent timeout", context.DeadlineExceeded, false},
		{"partial native failure", errors.Join(&fileassociations.FormatError{Extensions: []string{".txt"}, Err: os.ErrPermission}, context.Canceled), false},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := associationCanceled(test.err); got != test.want {
				t.Fatalf("cancellation-only = %t, want %t for %v", got, test.want, test.err)
			}
		})
	}
}
