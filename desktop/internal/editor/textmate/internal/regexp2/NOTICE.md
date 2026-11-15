# regexp2 fork

This directory is a copy of [github.com/dlclark/regexp2](https://github.com/dlclark/regexp2)
v1.12.0 (MIT, see `LICENSE`; `ATTRIB` keeps the upstream attributions of the .NET regex engine and
the PCRE test file). It is internal to the TextMate engine, which needs Oniguruma-compatible
matching that the standard library does not offer.

Lithe changed the copy in these places; everything else is upstream code:

- `syntax/charclass.go`: every character set the compiler emits is prepared with an ASCII bitmap
  and pre-resolved Unicode tables, so `CharIn` answers ASCII characters with one bit test.
  `IsWordChar` uses an ASCII table.
- `syntax/required.go` (new), `syntax/code.go`, `syntax/writer.go`: the compiler records the
  literals one of which every match must contain, and `runner.go` skips a scan whose remaining text
  contains none of them. The analysis is conservative: case-insensitive, right-to-left, set,
  anchor, back-reference, negative lookaround and conditional nodes contribute nothing.
- `regexp.go`, `runner.go`: `BacktrackLimit` and `ErrBacktrackLimit` bound a match by a
  deterministic number of backtracks instead of wall-clock time, and `FindRunesSpans` returns the
  group spans of the first match into a caller-owned slice without allocating.
- `match.go`: `compactBalancing` is split out of `tidy` for `FindRunesSpans`.
- Tests: `lithe_test.go` (new) covers the additions; the catastrophic-backtracking and PCRE tests
  use the backtrack limit instead of a timeout. `fuzz.go` and `fastclock_test.go` were removed.
