package workbench

import "strings"

// diffKind says what a line of an inline edit's diff does.
type diffKind uint8

const (
	diffSame diffKind = iota
	diffRemoved
	diffAdded
)

// diffLine is one line of the diff between the selection and the model's replacement.
type diffLine struct {
	kind diffKind
	text string
}

// diffCellLimit bounds the line-by-line comparison: a selection and a replacement whose
// product of line counts is larger is shown as everything removed and everything added.
const diffCellLimit = 4_000_000

// lineDiff compares two texts by line with a longest common subsequence.
func lineDiff(before, after string) []diffLine {
	a, b := splitLines(before), splitLines(after)
	if len(a)*len(b) > diffCellLimit {
		out := make([]diffLine, 0, len(a)+len(b))
		for _, line := range a {
			out = append(out, diffLine{diffRemoved, line})
		}
		for _, line := range b {
			out = append(out, diffLine{diffAdded, line})
		}
		return out
	}
	// lcs[i][j] is the length of the common subsequence of a[i:] and b[j:].
	lcs := make([][]int32, len(a)+1)
	for i := range lcs {
		lcs[i] = make([]int32, len(b)+1)
	}
	for i := len(a) - 1; i >= 0; i-- {
		for j := len(b) - 1; j >= 0; j-- {
			if a[i] == b[j] {
				lcs[i][j] = lcs[i+1][j+1] + 1
			} else {
				lcs[i][j] = max(lcs[i+1][j], lcs[i][j+1])
			}
		}
	}
	var out []diffLine
	i, j := 0, 0
	for i < len(a) && j < len(b) {
		switch {
		case a[i] == b[j]:
			out = append(out, diffLine{diffSame, a[i]})
			i++
			j++
		case lcs[i+1][j] >= lcs[i][j+1]:
			out = append(out, diffLine{diffRemoved, a[i]})
			i++
		default:
			out = append(out, diffLine{diffAdded, b[j]})
			j++
		}
	}
	for ; i < len(a); i++ {
		out = append(out, diffLine{diffRemoved, a[i]})
	}
	for ; j < len(b); j++ {
		out = append(out, diffLine{diffAdded, b[j]})
	}
	return out
}

func splitLines(text string) []string {
	if text == "" {
		return nil
	}
	return strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
}
