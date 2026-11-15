// Package sample shows Go syntax.
package sample

import (
	"context"
	"errors"
	"fmt"
	"strings"
)

// Shape is anything with an area.
type Shape interface {
	Area() float64
}

type Rect struct {
	W, H float64 `json:"w"`
	name string
}

type Number interface {
	~int | ~int64 | ~float64
}

const (
	KB = 1 << (10 * (iota + 1))
	MB
)

var ErrEmpty = errors.New("empty")

func (r *Rect) Area() float64 { return r.W * r.H }

func Sum[T Number](values ...T) (total T) {
	for _, v := range values {
		total += v
	}
	return
}

/*
Run starts the work and

	waits for it.
*/
func Run(ctx context.Context, names []string) (map[string]int, error) {
	if len(names) == 0 {
		return nil, fmt.Errorf("run: %w", ErrEmpty)
	}
	out := make(map[string]int, len(names))
	ch := make(chan string, 4)
	go func() {
		defer close(ch)
		for _, n := range names {
			select {
			case ch <- strings.ToUpper(n):
			case <-ctx.Done():
				return
			}
		}
	}()
	for n := range ch {
		switch {
		case n == "":
			continue
		default:
			out[n] = len(n)
		}
	}
	raw := `raw
string`
	r := 'x'
	_ = raw + string(r) + "\t\"quoted\"" + fmt.Sprint(0x1F, 1.5e3, 0o17, 1_000, true, nil)
	return out, nil
}
