// Package editorperf makes the documents the editor performance baseline measures: generated,
// deterministic texts of a fixed shape and size, so a result names exactly what it ran on and no
// multi-megabyte fixture is committed to the repository.
//
// A document is described by a Kind and a size. Text(kind, n) depends on nothing else: not on
// the machine, the Go release or the order in which documents were requested. Every kind
// except JSON is one endless stream of lines cut at the first line end at or after n bytes, so
// a smaller document is always a prefix of a larger one and a benchmark that grows its input
// keeps comparing the same text.
//
// The shapes are chosen to exercise the editor the way real files do: Go and Java source with
// comments, literals and nesting for the syntax highlighter, one enormous line for the layout
// code, prose that mixes Chinese and English for text measurement, logs for the long-file
// paths, and a mixed-script file with tabs, emoji, combining marks and CRLF line ends for the
// byte-versus-rune boundaries.
package editorperf

import (
	"bytes"
	"fmt"
	"math/big"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Kind names the shape of a generated document.
type Kind string

// The document kinds, in the order Kinds returns them.
const (
	Go       Kind = "go"       // gofmt-style Go source, tab indented
	Java     Kind = "java"     // Java source, 4-space indented, javadoc
	JSON     Kind = "json"     // minified JSON: the whole document is ONE line
	Markdown Kind = "markdown" // Chinese and English prose, lists, code fences
	Log      Kind = "log"      // timestamped log lines, stack traces
	Mixed    Kind = "mixed"    // tabs, CJK, emoji, combining marks, CRLF line ends
)

// Kinds returns every kind, in the order the constants are declared. Benchmarks range over it
// so a new kind joins every scenario without touching them.
func Kinds() []Kind {
	return []Kind{Go, Java, JSON, Markdown, Log, Mixed}
}

// Language returns the syntax registry language id that highlights the kind, or "" for a kind
// that has none: a log and the mixed-script file are plain text to the highlighter.
func (k Kind) Language() string {
	switch k {
	case Go:
		return "go"
	case Java:
		return "java"
	case JSON:
		return "json"
	case Markdown:
		return "markdown"
	}
	return ""
}

// The sizes of the baseline. A benchmark runs on a small document, which fits in cache and
// shows per-operation cost, and on a large one, which shows how the cost grows. The large size
// can be changed from the environment so a developer can try a heavier document without
// editing code; the default is what the recorded history was measured on.
const (
	SmallBytes        = 100 << 10
	DefaultLargeBytes = 10 << 20
	LargeBytesEnv     = "LITHE_EDITOR_PERF_LARGE_BYTES"
)

// The accepted range for a size read from the environment. Below the minimum a benchmark
// measures only its own overhead; above the maximum the generated document alone would take
// more memory than a benchmark run should ask of a machine.
const (
	minParsedBytes = 4096
	maxParsedBytes = 1 << 30
)

// Size is a document size together with the name a benchmark shows for it.
type Size struct {
	Name  string // e.g. "100KiB", "10MiB": always the last path segment of a benchmark name
	Bytes int
}

// Small returns the small size, SmallBytes.
func Small() Size {
	return Size{Name: SizeName(SmallBytes), Bytes: SmallBytes}
}

// Large returns the large size: LargeBytesEnv if it is set, otherwise DefaultLargeBytes. A
// value that does not parse panics with a message that names the variable, because a benchmark
// that silently fell back to the default would publish numbers for a size nobody asked for.
func Large() Size {
	value := os.Getenv(LargeBytesEnv)
	if value == "" {
		return Size{Name: SizeName(DefaultLargeBytes), Bytes: DefaultLargeBytes}
	}
	n, err := ParseBytes(value)
	if err != nil {
		panic(fmt.Sprintf("editorperf: %s=%q: %v", LargeBytesEnv, value, err))
	}
	return Size{Name: SizeName(n), Bytes: n}
}

// Sizes returns the sizes a benchmark runs on: Small, then Large. When both are the same size
// it returns only one, so the benchmark does not run the same case twice under one name.
func Sizes() []Size {
	small, large := Small(), Large()
	if small.Bytes == large.Bytes {
		return []Size{small}
	}
	return []Size{small, large}
}

// byteUnits maps a lower-case suffix to its size in bytes. Every unit is binary, as in the
// names SizeName writes, so "10m" and "10MiB" are the same size.
var byteUnits = map[string]int64{
	"": 1, "b": 1,
	"k": 1 << 10, "kb": 1 << 10, "kib": 1 << 10,
	"m": 1 << 20, "mb": 1 << 20, "mib": 1 << 20,
	"g": 1 << 30, "gb": 1 << 30, "gib": 1 << 30,
}

// ParseBytes reads a size: a plain integer number of bytes, or a number with a case-insensitive
// suffix among B, K, KB, KiB, M, MB, MiB, G, GB and GiB. All units are binary, so K is 1024.
// The number may be decimal ("1.5MiB") as long as the result is a whole number of bytes. The
// result must lie between 4096 bytes and 1 GiB; every error names the input.
func ParseBytes(s string) (int, error) {
	in := strings.TrimSpace(s)
	if in == "" {
		return 0, fmt.Errorf("size %q is empty", s)
	}
	end := 0
	for end < len(in) && (in[end] == '.' || (in[end] >= '0' && in[end] <= '9')) {
		end++
	}
	if end == 0 {
		return 0, fmt.Errorf("size %q does not start with a positive number", s)
	}
	suffix := strings.TrimSpace(in[end:])
	scale, ok := byteUnits[strings.ToLower(suffix)]
	if !ok {
		return 0, fmt.Errorf("size %q has the unknown unit %q: use B, KiB, MiB or GiB", s, suffix)
	}
	// A rational keeps "1.5MiB" exact. A float would turn a size such as "0.1KiB" into a
	// whole-looking number through rounding.
	number, ok := new(big.Rat).SetString(in[:end])
	if !ok {
		return 0, fmt.Errorf("size %q has the malformed number %q", s, in[:end])
	}
	total := number.Mul(number, new(big.Rat).SetInt64(scale))
	if !total.IsInt() {
		return 0, fmt.Errorf("size %q is not a whole number of bytes", s)
	}
	n := total.Num()
	if !n.IsInt64() || n.Int64() < minParsedBytes || n.Int64() > maxParsedBytes {
		return 0, fmt.Errorf("size %q is outside the range %s to %s", s, SizeName(minParsedBytes), SizeName(maxParsedBytes))
	}
	return int(n.Int64()), nil
}

// SizeName writes n in the largest binary unit that divides it exactly, such as "100KiB" or
// "10MiB", and in bytes when none does. The name is exact on purpose: a benchmark name must
// identify one size, and perfhistory compares names byte for byte.
func SizeName(n int) string {
	switch {
	case n <= 0:
		return strconv.Itoa(n) + "B"
	case n%(1<<30) == 0:
		return strconv.Itoa(n>>30) + "GiB"
	case n%(1<<20) == 0:
		return strconv.Itoa(n>>20) + "MiB"
	case n%(1<<10) == 0:
		return strconv.Itoa(n>>10) + "KiB"
	}
	return strconv.Itoa(n) + "B"
}

// cacheKey identifies a generated document.
type cacheKey struct {
	kind Kind
	n    int
}

// The cache holds every document that was asked for, for the life of the process. A benchmark
// calls Text once per sub-benchmark and again for every b.N round, and generating a 10 MiB
// document takes long enough to distort a short benchmark. The lock is held while generating,
// so concurrent callers of the same document wait for it instead of building it twice.
var (
	cacheMu sync.Mutex
	cache   = map[cacheKey][]byte{}
)

// Text returns the deterministic document of kind of at least n bytes: whole lines, so it is
// longer than n by at most one line. The result is cached and shared: callers must never
// modify it. Text panics on an unknown kind or an n that is not positive, because both are
// mistakes in the benchmark and not conditions to recover from.
func Text(kind Kind, n int) []byte {
	if _, ok := seeds[kind]; !ok {
		panic(fmt.Sprintf("editorperf: unknown kind %q", string(kind)))
	}
	if n <= 0 {
		panic(fmt.Sprintf("editorperf: size %d is not positive", n))
	}
	key := cacheKey{kind: kind, n: n}
	cacheMu.Lock()
	defer cacheMu.Unlock()
	if text, ok := cache[key]; ok {
		return text
	}
	text := generate(kind, n)
	cache[key] = text
	return text
}

// LiveHeap runs the collector twice and returns runtime.MemStats.HeapAlloc, for measuring what
// a document keeps alive. The second collection finishes what the first one's finalizers and
// sweeping left behind. The documents Text caches count toward the result, so measure the
// difference between two calls and not the absolute value.
func LiveHeap() uint64 {
	runtime.GC()
	runtime.GC()
	var stats runtime.MemStats
	runtime.ReadMemStats(&stats)
	return stats.HeapAlloc
}

// rng is splitmix64. It is written out here instead of using math/rand because a fixture must
// stay byte-for-byte the same forever, and the stream math/rand produces for a seed may change
// between Go releases. The algorithm is eight lines and defines its output completely.
type rng struct{ state uint64 }

// next returns the next 64 random bits.
func (r *rng) next() uint64 {
	r.state += 0x9e3779b97f4a7c15
	z := r.state
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ^ (z >> 27)) * 0x94d049bb133111eb
	return z ^ (z >> 31)
}

// intn returns a number in [0, n). The modulo bias is irrelevant for a fixture, and modulo
// keeps the mapping from bits to choices trivially stable.
func (r *rng) intn(n int) int {
	return int(r.next() % uint64(n))
}

// between returns a number in [lo, hi], both ends included.
func (r *rng) between(lo, hi int) int {
	return lo + r.intn(hi-lo+1)
}

// chance reports true on average once in n calls.
func (r *rng) chance(n int) bool {
	return r.intn(n) == 0
}

// pick returns a member of list.
func (r *rng) pick(list []string) string {
	return list[r.intn(len(list))]
}

// vocabulary is the English word list identifiers, names and prose are built from. It holds
// only lower-case ASCII words that are keywords in neither Go nor Java, so a word can be used
// as an identifier as it is.
var vocabulary = []string{
	"anchor", "buffer", "cache", "chunk", "cursor", "column", "command", "config",
	"delta", "document", "editor", "event", "file", "filter", "glyph", "handle",
	"height", "index", "layout", "line", "margin", "marker", "match", "matrix",
	"module", "node", "offset", "option", "pane", "parser", "patch", "plugin",
	"queue", "reader", "region", "render", "request", "response", "result", "scan",
	"scope", "script", "session", "signal", "source", "state", "status", "symbol",
	"tab", "target", "theme", "timer", "token", "tree", "vector", "viewport",
	"widget", "width", "window", "worker", "writer",
}

// word returns one word of the vocabulary.
func (r *rng) word() string {
	return r.pick(vocabulary)
}

// phrase returns n words separated by spaces.
func (r *rng) phrase(n int) string {
	parts := make([]string, n)
	for i := range parts {
		parts[i] = r.word()
	}
	return strings.Join(parts, " ")
}

// camel returns n words joined as a camelCase identifier.
func (r *rng) camel(n int) string {
	var b strings.Builder
	for i := range n {
		w := r.word()
		if i > 0 {
			w = capitalize(w)
		}
		b.WriteString(w)
	}
	return b.String()
}

// pascal returns n words joined as a PascalCase identifier.
func (r *rng) pascal(n int) string {
	var b strings.Builder
	for range n {
		b.WriteString(capitalize(r.word()))
	}
	return b.String()
}

// capitalize upper-cases the first byte of an ASCII word.
func capitalize(s string) string {
	if s == "" {
		return s
	}
	return strings.ToUpper(s[:1]) + s[1:]
}

// pad right-pads s with spaces to width bytes, the way gofmt aligns the columns of a struct.
func pad(s string, width int) string {
	if len(s) >= width {
		return s
	}
	return s + strings.Repeat(" ", width-len(s))
}

// seeds holds the fixed seed of every kind. They are arbitrary, and different, so the kinds do
// not share a random stream. Changing one changes the text, which breaks every recorded
// baseline that ran on it.
var seeds = map[Kind]uint64{
	Go:       0x1f83d9abfb41bd6b,
	Java:     0x5be0cd19137e2179,
	JSON:     0x9b05688c2b3e6c1f,
	Markdown: 0x510e527fade682d1,
	Log:      0x3c6ef372fe94f82b,
	Mixed:    0xa54ff53a5f1d36f1,
}

// generator produces the units of one kind: a unit is a few lines that belong together, such
// as a function with its doc comment. The unit sequence is endless and depends only on the
// kind, which is what makes every document a prefix of the next larger one.
type generator struct {
	kind   Kind
	rng    rng
	buf    []byte // the unit being written; for JSON, the whole document
	indent string // one level of indentation
	units  int    // units produced so far
	clock  int64  // Log: milliseconds since the Unix epoch of the last line
	ret    string // Go: the values returned before the error, such as "0, "
}

// newGenerator starts the stream of a kind from its beginning.
func newGenerator(kind Kind) *generator {
	g := &generator{kind: kind, rng: rng{state: seeds[kind]}, indent: "\t"}
	switch kind {
	case Java:
		g.indent = "    "
	case Log:
		g.clock = time.Date(2026, time.November, 9, 8, 15, 42, 123_000_000, time.UTC).UnixMilli()
	}
	return g
}

// generate builds the document of kind: the line stream cut at the first line end at or after
// n bytes. The cut is by line and not by unit so that the text depends on n as little as
// possible, and a line is short enough (under 1 KiB) that the overshoot stays small.
func generate(kind Kind, n int) []byte {
	g := newGenerator(kind)
	if kind == JSON {
		return g.jsonDocument(n)
	}
	out := make([]byte, 0, n+1024)
	for len(out) < n {
		rest := g.unit()
		for len(rest) > 0 && len(out) < n {
			end := bytes.IndexByte(rest, '\n') + 1
			if end == 0 {
				end = len(rest)
			}
			out = append(out, rest[:end]...)
			rest = rest[end:]
		}
	}
	return out
}

// unit writes the next unit of the stream into the buffer and returns it. Every unit ends with
// a line end, so the caller can cut between units or between lines.
func (g *generator) unit() []byte {
	g.buf = g.buf[:0]
	switch g.kind {
	case Go:
		g.goUnit()
	case Java:
		g.javaUnit()
	case Markdown:
		g.markdownUnit()
	case Log:
		g.logUnit()
	case Mixed:
		g.mixedUnit()
	default:
		panic(fmt.Sprintf("editorperf: kind %q is not a line stream", string(g.kind)))
	}
	g.units++
	return g.buf
}

// str appends s to the buffer.
func (g *generator) str(s string) {
	g.buf = append(g.buf, s...)
}

// f appends formatted text to the buffer.
func (g *generator) f(format string, args ...any) {
	g.buf = fmt.Appendf(g.buf, format, args...)
}

// ln appends one line, indented by depth levels.
func (g *generator) ln(depth int, s string) {
	for range depth {
		g.buf = append(g.buf, g.indent...)
	}
	g.buf = append(g.buf, s...)
	g.buf = append(g.buf, '\n')
}

// lnf appends one formatted line, indented by depth levels.
func (g *generator) lnf(depth int, format string, args ...any) {
	g.ln(depth, fmt.Sprintf(format, args...))
}

// blank appends an empty line.
func (g *generator) blank() {
	g.buf = append(g.buf, '\n')
}

// compareOps are the comparison operators both Go and Java conditions use.
var compareOps = []string{"==", "!=", "<", ">", "<=", ">="}

// Go source.

// goMaxDepth is the indentation level from which only simple statements are written. Real code
// is rarely nested deeper than three tabs, and a bound keeps the distribution of line lengths
// steady.
const goMaxDepth = 3

var goFuncDocs = []string{
	"validates the request before it reaches the view.",
	"reports whether the range still lies inside the document.",
	"returns the cached result when the revision has not changed.",
	"walks the tree from the root and stops at the first match.",
	"copies the affected lines so the caller may keep editing.",
	"is safe for concurrent use by multiple goroutines.",
	"applies the pending edits in the order they were made.",
	"releases everything the session holds and may be called twice.",
	"converts a byte offset into a line and column pair.",
	"waits for the worker and returns the first error it saw.",
}

var goMoreDocs = []string{
	"The result is valid until the next edit.",
	"It never blocks on the file system.",
	"Callers must not modify the returned slice.",
	"A negative limit means no limit.",
	"The zero value is ready to use.",
	"See the package documentation for the reasoning.",
}

var goTypeDocs = []string{
	"holds the state the view needs between two frames.",
	"describes one entry in the result list.",
	"is the wire format of a plugin message.",
	"says which part of the document an action applies to.",
	"selects how the editor treats the next keystroke.",
	"is what the settings page shows for one option.",
}

var goVarDocs = []string{
	"is used when the caller supplies no options.",
	"is the starting point for every new session.",
	"holds the values a fresh window opens with.",
}

var goFieldTypes = []string{
	"string", "int", "int64", "bool", "float64", "[]string", "map[string]int", "time.Time",
	"*Options", "[]byte",
}

var goParamList = []string{
	"name string", "limit int", "data []byte", "ctx context.Context", "opts *Options",
	"items []string", "ratio float64", "w io.Writer",
}

// goUnit writes one declaration: the header first, then an endless mix of functions, methods,
// structs, constant blocks and variable blocks.
func (g *generator) goUnit() {
	if g.units == 0 {
		g.goHeader()
		return
	}
	p := g.rng.intn(100)
	switch {
	case p < 52:
		g.goFunc(false)
	case p < 68:
		g.goFunc(true)
	case p < 80:
		g.goStruct()
	case p < 90:
		g.goConsts()
	default:
		g.goVars()
	}
}

// goHeader writes the package clause and the import block.
func (g *generator) goHeader() {
	g.ln(0, "package bench")
	g.blank()
	g.ln(0, "import (")
	for _, path := range []string{"context", "errors", "fmt", "io", "strings", "sync", "time"} {
		g.ln(1, strconv.Quote(path))
	}
	g.ln(0, ")")
	g.blank()
}

// goFunc writes a function or method with its doc comment and a body of 5 to 25 lines.
func (g *generator) goFunc(method bool) {
	r := &g.rng
	name := r.pascal(2)
	for i, n := 0, r.between(1, 3); i < n; i++ {
		if i == 0 {
			g.ln(0, "// "+name+" "+r.pick(goFuncDocs))
		} else {
			g.ln(0, "// "+r.pick(goMoreDocs))
		}
	}
	recv := ""
	if method {
		typ := r.pascal(1)
		recv = "(" + strings.ToLower(typ[:1]) + " *" + typ + ") "
	}
	g.ret = ""
	results := "error"
	if r.chance(4) {
		g.ret = "0, "
		results = "(int, error)"
	}
	g.ln(0, "func "+recv+name+"("+g.goParams()+") "+results+" {")
	for lines, target := 0, r.between(5, 25); lines < target; {
		lines += g.goStmt(1)
	}
	g.ln(1, "return "+g.ret+"nil")
	g.ln(0, "}")
	g.blank()
}

// goParams returns a parameter list of up to three distinct parameters.
func (g *generator) goParams() string {
	r := &g.rng
	n := r.intn(4)
	start := r.intn(len(goParamList))
	params := make([]string, 0, n)
	for k := range n {
		params = append(params, goParamList[(start+k)%len(goParamList)])
	}
	return strings.Join(params, ", ")
}

// goStmt writes one statement and returns the number of lines it took. Compound statements
// recurse until goMaxDepth.
func (g *generator) goStmt(depth int) int {
	r := &g.rng
	kind := r.intn(17)
	if depth >= goMaxDepth && kind < 6 {
		kind += 6
	}
	switch kind {
	case 0, 1:
		g.lnf(depth, "if err := %s.%s(%s); err != nil {", r.camel(1), r.pascal(1), r.camel(1))
		g.lnf(depth+1, "return %sfmt.Errorf(\"%s %s: %%w\", err)", g.ret, r.word(), r.word())
		g.ln(depth, "}")
		return 3
	case 2:
		if r.chance(2) {
			g.lnf(depth, "for i := 0; i < len(%s); i++ {", r.camel(1))
		} else {
			g.lnf(depth, "for _, %s := range %s {", r.camel(1), r.camel(1))
		}
		n := 2
		for range r.between(1, 3) {
			n += g.goStmt(depth + 1)
		}
		g.ln(depth, "}")
		return n
	case 3:
		g.lnf(depth, "switch %s.%s {", r.camel(1), r.camel(1))
		n := 4
		byName := r.chance(2)
		for range r.between(2, 3) {
			if byName {
				g.lnf(depth, "case %q:", r.word())
			} else {
				g.lnf(depth, "case %d, 0x%x:", r.intn(10), r.intn(256))
			}
			n += 1 + g.goStmt(depth+1)
		}
		g.ln(depth, "default:")
		g.lnf(depth+1, "return %sfmt.Errorf(\"unexpected %s\")", g.ret, r.word())
		g.ln(depth, "}")
		return n
	case 4:
		g.lnf(depth, "if %s.%s %s %d {", r.camel(1), r.camel(1), r.pick(compareOps), r.intn(100))
		n := 2 + g.goStmt(depth+1)
		if r.chance(3) {
			g.ln(depth, "} else {")
			n += 1 + g.goStmt(depth+1)
		}
		g.ln(depth, "}")
		return n
	case 5:
		g.ln(depth, "defer func() {")
		n := 2 + g.goStmt(depth+1)
		g.ln(depth, "}()")
		return n
	case 6:
		g.lnf(depth, "%s := %s.%s(%s)", r.camel(r.between(1, 2)), r.camel(1), r.pascal(1), r.camel(1))
	case 7:
		// Escapes inside an interpreted string literal: the highlighter must not end the string
		// at the escaped quote.
		if r.chance(2) {
			g.lnf(depth, `%s := "\"%s\"\t%s\n"`, r.camel(1), r.word(), r.word())
		} else {
			g.lnf(depth, `fmt.Fprintf(w, "%%s\t%%d\n", %s, %s)`, r.camel(1), r.camel(1))
		}
	case 8:
		switch r.intn(3) {
		case 0:
			g.lnf(depth, "%s := %s & 0x%X", r.camel(1), r.camel(1), r.intn(65536))
		case 1:
			g.lnf(depth, "%s := %d.%02d * 1e%d", r.camel(1), r.intn(100), r.intn(100), r.between(1, 9))
		default:
			g.lnf(depth, "%s <<= 0x%x", r.camel(1), r.between(1, 12))
		}
	case 9:
		if r.chance(2) {
			g.lnf(depth, "%s := `select %s from %s where %s = ?`", r.camel(1), r.word(), r.word(), r.word())
		} else {
			g.lnf(depth, "%s := regexp.MustCompile(`^[a-z]+\\d{2}%s$`)", r.camel(1), r.word())
		}
	case 10:
		if r.chance(2) {
			g.ln(depth, "/* "+r.phrase(r.between(3, 6))+" */")
		} else {
			g.lnf(depth, "%s := %d /* %s */", r.camel(1), r.intn(1000), r.phrase(2))
		}
	case 11:
		name := r.camel(1)
		g.lnf(depth, "%s = append(%s, %s)", name, name, r.camel(1))
	case 12:
		mu := r.camel(1) + "Mu"
		g.ln(depth, mu+".Lock()")
		g.ln(depth, "defer "+mu+".Unlock()")
		return 2
	case 13:
		// The occasional long line: the editor must lay out lines of 120 to 160 bytes as well as
		// the typical 40.
		g.lnf(depth, "%s.logger.Printf(\"%s at offset %%d (limit %%d): %%v\", off, limit, err)", r.camel(1), r.phrase(r.between(7, 10)))
	case 14:
		g.lnf(depth, "%s.%s += %s", r.camel(1), r.camel(1), r.camel(1))
	case 15:
		g.lnf(depth, "%s += len(%s)", r.camel(1), r.camel(1))
	default:
		g.ln(depth, "// "+r.phrase(r.between(3, 7)))
	}
	return 1
}

// goStruct writes a struct type with tagged fields, aligned the way gofmt aligns them.
func (g *generator) goStruct() {
	r := &g.rng
	name := r.pascal(r.between(1, 2))
	g.ln(0, "// "+name+" "+r.pick(goTypeDocs))
	g.ln(0, "type "+name+" struct {")
	n := r.between(3, 8)
	names := make([]string, n)
	types := make([]string, n)
	tags := make([]string, n)
	nameWidth, typeWidth := 0, 0
	for i := range n {
		w := r.word()
		field, tag := capitalize(w), w
		if r.chance(3) {
			w2 := r.word()
			field += capitalize(w2)
			tag += "_" + w2
		}
		if r.chance(3) {
			tag += ",omitempty"
		}
		names[i] = field
		types[i] = r.pick(goFieldTypes)
		tags[i] = "`json:\"" + tag + "\"`"
		nameWidth = max(nameWidth, len(names[i]))
		typeWidth = max(typeWidth, len(types[i]))
	}
	for i := range n {
		g.ln(1, pad(names[i], nameWidth)+" "+pad(types[i], typeWidth)+" "+tags[i])
	}
	g.ln(0, "}")
	g.blank()
}

// goConsts writes an enumeration with iota, or a block of plain constants.
func (g *generator) goConsts() {
	r := &g.rng
	if r.chance(3) {
		size := 1 << r.between(8, 16)
		g.ln(0, "const (")
		g.lnf(1, "max%s = 0x%X", r.pascal(1), size)
		g.lnf(1, "default%s = %d.%d", r.pascal(1), r.intn(10), r.intn(100))
		g.lnf(1, "%sTimeout = %d * time.Second", r.camel(1), r.between(1, 60))
		g.ln(0, ")")
		g.blank()
		return
	}
	typ := r.pascal(1)
	g.ln(0, "// "+typ+" "+r.pick(goTypeDocs))
	g.ln(0, "type "+typ+" int")
	g.blank()
	g.ln(0, "const (")
	shift := r.chance(3)
	for i, n := 0, r.between(3, 8); i < n; i++ {
		name := typ + capitalize(r.word())
		switch {
		case i == 0 && shift:
			g.ln(1, name+" "+typ+" = 1 << iota")
		case i == 0:
			g.ln(1, name+" "+typ+" = iota")
		default:
			g.ln(1, name)
		}
	}
	g.ln(0, ")")
	g.blank()
}

// goVars writes a variable with a composite literal, or a block of variables.
func (g *generator) goVars() {
	r := &g.rng
	if r.chance(2) {
		typ := r.pascal(1)
		g.ln(0, "// default"+typ+" "+r.pick(goVarDocs))
		g.ln(0, "var default"+typ+" = "+typ+"{")
		n := r.between(3, 7)
		keys := make([]string, n)
		values := make([]string, n)
		width := 0
		for i := range n {
			keys[i] = capitalize(r.word()) + ":"
			values[i] = g.goLiteral()
			width = max(width, len(keys[i]))
		}
		for i := range n {
			g.ln(1, pad(keys[i], width)+" "+values[i]+",")
		}
		g.ln(0, "}")
		g.blank()
		return
	}
	g.ln(0, "var (")
	for range r.between(2, 5) {
		switch r.intn(4) {
		case 0:
			g.lnf(1, "err%s = errors.New(%q)", r.pascal(2), r.phrase(3))
		case 1:
			g.lnf(1, "%s = []string{%q, %q, %q}", r.camel(1), r.word(), r.word(), r.word())
		case 2:
			g.lnf(1, "%s = map[string]int{%q: %d, %q: %d}", r.camel(1), r.word(), r.intn(100), r.word(), r.intn(100))
		default:
			g.lnf(1, "%s = %s{%s: %d, %s: %q}", r.camel(1), r.pascal(1), capitalize(r.word()), r.intn(1000), capitalize(r.word()), r.word())
		}
	}
	g.ln(0, ")")
	g.blank()
}

// goLiteral returns a value for a field of a composite literal.
func (g *generator) goLiteral() string {
	r := &g.rng
	switch r.intn(6) {
	case 0:
		return strconv.Quote(r.phrase(2))
	case 1:
		return fmt.Sprintf("0x%X", r.intn(65536))
	case 2:
		return fmt.Sprintf("%d.%02d", r.intn(10), r.intn(100))
	case 3:
		return fmt.Sprintf("[]string{%q, %q}", r.word(), r.word())
	case 4:
		return strconv.FormatBool(r.chance(2))
	}
	return fmt.Sprintf("%d * time.Second", r.between(1, 60))
}

// Java source.

// javaReturns are the return types of generated methods with a value a method can end with.
var javaReturns = []struct{ typ, zero string }{
	{"void", ""},
	{"int", "0"},
	{"String", `""`},
	{"boolean", "false"},
	{"List<String>", "new ArrayList<>()"},
	{"Map<String, List<Integer>>", "new HashMap<>()"},
}

var javaParams = []string{
	"String name", "int limit", "List<String> items", "Map<String, List<Integer>> index",
	"boolean strict", "char separator", "long timeout", "double ratio",
}

var javaTypes = []string{"String", "int", "long", "double", "boolean"}

// javaChars are char literals, quotes included, among them the escapes that trip a highlighter.
var javaChars = []string{"';'", "','", `'\t'`, `'\n'`, `'\''`, "'x'"}

// javaUnit writes one top-level type: the header first, then classes and interfaces.
func (g *generator) javaUnit() {
	if g.units == 0 {
		g.ln(0, "package com.example.bench;")
		g.blank()
		for _, path := range []string{
			"java.io.IOException", "java.util.ArrayList", "java.util.HashMap", "java.util.List",
			"java.util.Map", "java.util.function.Function",
		} {
			g.ln(0, "import "+path+";")
		}
		g.blank()
		return
	}
	if g.rng.chance(4) {
		g.javaInterface()
	} else {
		g.javaClass()
	}
}

// javadoc writes a documentation comment: the summary lines, then one @param per parameter and
// an @return when ret is not empty.
func (g *generator) javadoc(depth int, summary, params []string, ret bool) {
	r := &g.rng
	g.ln(depth, "/**")
	for _, line := range summary {
		g.ln(depth, " * "+line)
	}
	if len(params) > 0 || ret {
		g.ln(depth, " *")
	}
	for _, p := range params {
		g.ln(depth, " * @param "+p+" "+r.phrase(r.between(3, 6)))
	}
	if ret {
		g.ln(depth, " * @return "+r.phrase(r.between(3, 6)))
	}
	g.ln(depth, " */")
}

// javaParamDecls returns up to three distinct parameter declarations and their names.
func (g *generator) javaParamDecls() (decls, names []string) {
	r := &g.rng
	n := r.intn(4)
	start := r.intn(len(javaParams))
	for k := range n {
		decl := javaParams[(start+k)%len(javaParams)]
		decls = append(decls, decl)
		names = append(names, decl[strings.LastIndexByte(decl, ' ')+1:])
	}
	return decls, names
}

// javaClass writes a documented class: fields, then two to five methods.
func (g *generator) javaClass() {
	r := &g.rng
	name := r.pascal(r.between(1, 2))
	summary := []string{"Keeps the " + r.phrase(3) + " of one " + r.word() + "."}
	if r.chance(2) {
		summary = append(summary, "<p>"+capitalize(r.phrase(r.between(5, 9)))+".")
	}
	g.javadoc(0, summary, nil, false)
	if r.chance(5) {
		g.ln(0, "@Deprecated")
	}
	switch r.intn(3) {
	case 0:
		g.ln(0, "public class "+name+" {")
	case 1:
		g.ln(0, "public final class "+name+" {")
	default:
		g.ln(0, "public class "+name+"<T> {")
	}
	g.blank()
	for range r.between(1, 4) {
		g.javaField()
	}
	g.blank()
	for range r.between(2, 5) {
		g.javaMethod()
	}
	g.ln(0, "}")
	g.blank()
}

// javaField writes one field of a class.
func (g *generator) javaField() {
	r := &g.rng
	switch r.intn(7) {
	case 0:
		g.lnf(1, "private final Map<String, List<Integer>> %s = new HashMap<>();", r.camel(1))
	case 1:
		g.lnf(1, "private static final int %s = 0x%X;", strings.ToUpper(r.word()), 1<<r.between(8, 16))
	case 2:
		g.lnf(1, "private char %s = %s;", r.camel(1), r.pick(javaChars))
	case 3:
		g.lnf(1, `private String %s = "%s \"%s\"";`, r.camel(1), r.word(), r.word())
	case 4:
		g.lnf(1, "private final List<String> %s = new ArrayList<>();", r.camel(1))
	case 5:
		g.lnf(1, "private double %s = %d.%d;", r.camel(1), r.intn(10), r.intn(100))
	default:
		g.lnf(1, "private long %s = %d_000L;", r.camel(1), r.between(1, 90))
	}
}

// javaMethod writes a documented method of 3 to 14 body lines, followed by a blank line.
func (g *generator) javaMethod() {
	r := &g.rng
	name := r.camel(r.between(1, 2))
	ret := javaReturns[r.intn(len(javaReturns))]
	decls, names := g.javaParamDecls()
	g.javadoc(1, []string{"Returns the " + r.phrase(3) + " of the given " + r.word() + "."}, names, ret.typ != "void")
	switch {
	case r.chance(4):
		g.ln(1, "@Override")
	case r.chance(10):
		g.ln(1, "@Deprecated")
	}
	signature := "public " + ret.typ + " " + name + "(" + strings.Join(decls, ", ") + ")"
	if r.chance(6) {
		signature += " throws IOException"
	}
	g.ln(1, signature+" {")
	for lines, target := 0, r.between(3, 14); lines < target; {
		lines += g.javaStmt(2)
	}
	if ret.typ != "void" {
		g.ln(2, "return "+ret.zero+";")
	}
	g.ln(1, "}")
	g.blank()
}

// javaStmt writes one statement and returns the number of lines it took. Compound statements
// recurse until four levels of indentation.
func (g *generator) javaStmt(depth int) int {
	r := &g.rng
	kind := r.intn(16)
	if depth >= 4 && kind < 6 {
		kind += 6
	}
	switch kind {
	case 0:
		g.lnf(depth, "for (int i = 0; i < %s.size(); i++) {", r.camel(1))
		n := 2
		for range r.between(1, 3) {
			n += g.javaStmt(depth + 1)
		}
		g.ln(depth, "}")
		return n
	case 1:
		g.lnf(depth, "for (String %s : %s) {", r.camel(1), r.camel(1))
		n := 2
		for range r.between(1, 3) {
			n += g.javaStmt(depth + 1)
		}
		g.ln(depth, "}")
		return n
	case 2:
		g.ln(depth, "try {")
		n := 4 + g.javaStmt(depth+1)
		g.ln(depth, "} catch (IOException e) {")
		g.lnf(depth+1, "throw new IllegalStateException(\"failed to %s the %s\", e);", r.word(), r.word())
		if r.chance(3) {
			g.ln(depth, "} finally {")
			g.lnf(depth+1, "%s.close();", r.camel(1))
			n += 2
		}
		g.ln(depth, "}")
		return n
	case 3:
		g.lnf(depth, "switch (%s) {", r.camel(1))
		n := 4
		for range r.between(2, 3) {
			g.lnf(depth+1, "case %q:", r.word())
			n += 2 + g.javaStmt(depth+2)
			g.ln(depth+2, "break;")
		}
		g.ln(depth+1, "default:")
		g.ln(depth+2, "break;")
		g.ln(depth, "}")
		return n
	case 4:
		g.lnf(depth, "if (%s.%s() %s %d) {", r.camel(1), r.camel(1), r.pick(compareOps), r.intn(100))
		n := 2 + g.javaStmt(depth+1)
		if r.chance(3) {
			g.ln(depth, "} else {")
			n += 1 + g.javaStmt(depth+1)
		}
		g.ln(depth, "}")
		return n
	case 5:
		g.ln(depth, "executor.submit(() -> {")
		n := 2 + g.javaStmt(depth+1)
		g.ln(depth, "});")
		return n
	case 6:
		g.lnf(depth, "%s %s = %s.%s(%s);", r.pick(javaTypes), r.camel(1), r.camel(1), r.camel(1), r.camel(1))
	case 7:
		g.lnf(depth, "List<String> %s = new ArrayList<>();", r.camel(1))
	case 8:
		g.lnf(depth, "Map<String, List<Integer>> %s = new HashMap<>();", r.camel(1))
	case 9:
		// Lambdas, in the shapes real code uses them.
		switch r.intn(5) {
		case 0:
			g.lnf(depth, "Function<String, Integer> %s = s -> s.length();", r.camel(1))
		case 1:
			g.lnf(depth, "%s.computeIfAbsent(%s, k -> new ArrayList<>()).add(i);", r.camel(1), r.camel(1))
		case 2:
			g.lnf(depth, "%s.forEach(item -> System.out.println(item));", r.camel(1))
		case 3:
			g.lnf(depth, "%s.removeIf(item -> item.isEmpty());", r.camel(1))
		default:
			g.lnf(depth, "%s.sort((a, b) -> Integer.compare(a.length(), b.length()));", r.camel(1))
		}
	case 10:
		g.lnf(depth, "char %s = %s;", r.camel(1), r.pick(javaChars))
	case 11:
		g.lnf(depth, `String %s = "say \"%s\"\t" + %s + "\n";`, r.camel(1), r.word(), r.camel(1))
	case 12:
		switch r.intn(3) {
		case 0:
			g.lnf(depth, "int %s = 0x%X;", r.camel(1), r.intn(65536))
		case 1:
			g.lnf(depth, "double %s = %d.%02d;", r.camel(1), r.intn(100), r.intn(100))
		default:
			g.lnf(depth, "long %s = 0x%XL;", r.camel(1), r.intn(1<<24))
		}
	case 13:
		if r.chance(2) {
			g.lnf(depth, "System.out.println(\"%s \" + %s);", r.word(), r.camel(1))
		} else {
			g.lnf(depth, "%s.%s(%s);", r.camel(1), r.camel(1), r.camel(1))
		}
	case 14:
		g.lnf(depth, "if (%s == null) {", r.camel(1))
		g.lnf(depth+1, "throw new IllegalArgumentException(\"%s must not be null\");", r.word())
		g.ln(depth, "}")
		return 3
	default:
		if r.chance(2) {
			g.ln(depth, "// "+r.phrase(r.between(3, 7)))
		} else {
			g.ln(depth, "/* "+r.phrase(r.between(2, 5))+" */")
		}
	}
	return 1
}

// javaInterface writes a documented interface of two to five methods.
func (g *generator) javaInterface() {
	r := &g.rng
	name := r.pascal(r.between(1, 2))
	g.javadoc(0, []string{"Describes the " + r.phrase(3) + " of a " + r.word() + "."}, nil, false)
	if r.chance(6) {
		g.ln(0, "@FunctionalInterface")
	}
	g.ln(0, "public interface "+name+"<T> {")
	g.blank()
	for range r.between(2, 5) {
		ret := javaReturns[r.intn(len(javaReturns))]
		decls, names := g.javaParamDecls()
		g.javadoc(1, []string{"Returns the " + r.phrase(3) + " of the given " + r.word() + "."}, names, ret.typ != "void")
		g.ln(1, ret.typ+" "+r.camel(r.between(1, 2))+"("+strings.Join(decls, ", ")+");")
		g.blank()
	}
	if r.chance(3) {
		g.javadoc(1, []string{"Tells whether there is no " + r.word() + "."}, nil, true)
		g.ln(1, "default boolean is"+r.pascal(1)+"Empty() {")
		g.ln(2, "return size() == 0;")
		g.ln(1, "}")
		g.blank()
	}
	g.ln(0, "}")
	g.blank()
}

// JSON.

// jsonDocument writes {"items":[ record, record, ... ]} as one line. The records are added
// until the document reaches n bytes with its closing "]}" and line end.
func (g *generator) jsonDocument(n int) []byte {
	g.buf = make([]byte, 0, n+256)
	g.str(`{"items":[`)
	for i := 0; ; i++ {
		if i > 0 {
			g.str(",")
		}
		g.jsonRecord()
		if len(g.buf) >= n-3 {
			break
		}
	}
	g.str("]}\n")
	return g.buf
}

// jsonUnicode are names written as UTF-8 and not as escapes.
var jsonUnicode = []string{"中文", "日本語", "한국어"}

// jsonRecord writes one object, with the values varied the way an API response varies them.
func (g *generator) jsonRecord() {
	r := &g.rng
	g.f(`{"id":%d,"name":%s,"tags":[`, r.intn(100000), g.jsonString())
	for i := range r.intn(5) {
		if i > 0 {
			g.str(",")
		}
		g.f("%q", r.word())
	}
	g.f(`],"active":%t,"score":`, r.chance(2))
	switch r.intn(4) {
	case 0:
		g.f("%d", r.intn(1000))
	case 1:
		g.f("%d.%d", r.intn(100), r.intn(10))
	case 2:
		g.f("%d.%03d", r.intn(1000), r.intn(1000))
	default:
		g.f("%d.%de%d", r.between(1, 9), r.intn(10), r.between(1, 6))
	}
	g.f(`,"nested":{"key":%q,"list":[`, r.word())
	for i := range r.between(1, 6) {
		if i > 0 {
			g.str(",")
		}
		g.f("%d", r.intn(2001)-1000)
	}
	g.str("]}")
	if r.chance(3) {
		g.f(`,"path":"/src/%s/%s.go"`, r.word(), r.word())
	}
	if r.chance(5) {
		g.str(`,"parent":null`)
	}
	g.str("}")
}

// jsonString returns a quoted JSON string: usually plain words, sometimes with the escapes and
// the multi-byte text that a parser and a highlighter must handle.
func (g *generator) jsonString() string {
	r := &g.rng
	switch r.intn(8) {
	case 0:
		return `"` + r.word() + ` \"` + r.word() + `\""`
	case 1:
		return `"` + r.word() + `\t` + r.word() + `"`
	case 2:
		return `"` + r.word() + ` caf\u00e9"`
	case 3:
		return `"` + r.pick(jsonUnicode) + `"`
	}
	return `"` + r.phrase(r.between(1, 3)) + `"`
}

// Markdown.

// mdSentences are the Chinese sentences of the prose, each at most 28 characters so a
// paragraph line stays under the 300 bytes the shape promises.
var mdSentences = []string{
	"编辑器打开大文件时，响应速度比功能数量更重要。",
	"每次按键之后，界面应当在一帧之内完成重绘。",
	"文件在磁盘上的字节需要先解码，再交给文本缓冲区。",
	"语法高亮应当在后台逐行进行，而不是阻塞输入。",
	"插件通过明确的接口扩展编辑器，而不是修改核心代码。",
	"性能基线记录的是同一份文档上的耗时和内存。",
	"撤销和重做依赖不可变的文本，旧版本几乎不占额外空间。",
	"搜索结果需要按行号排序，并在滚动时保持稳定。",
	"当文件包含很长的单行时，换行计算必须有上限。",
	"保存文件之前要确认编码和行尾符没有被意外改变。",
	"标签页切换应该立即生效，不能等待文件重新加载。",
	"日志里的时间戳帮助我们还原一次操作的完整过程。",
	"插件崩溃时，编辑器本身应该继续正常工作。",
	"测试数据由程序生成，因此每次运行得到的文档完全相同。",
	"光标移动、选区扩展和多光标编辑都建立在偏移量之上。",
	"内存占用要在垃圾回收之后测量，才能反映文档真正占用的空间。",
	"设置页面显示的是工具真实的配置，而不是另一份影子配置。",
	"表格、列表和代码块是文档中最常见的结构。",
	"语言服务器返回的诊断信息会显示在状态栏和问题面板中。",
	"用户可以拖动分隔条调整面板大小，拖动过程中不应该卡顿。",
	"项目树展开成千上万个文件时，仍然要保持滚动流畅。",
	"这个版本改进了大文件的打开速度，并减少了启动时的内存峰值。",
}

var mdHeadings = []string{
	"性能基线", "文件与编码", "插件接口", "搜索与替换", "快捷键", "常见问题", "设计取舍", "测试方法",
}

var mdTableHeads = []string{
	"| Name | Value | Notes |",
	"| Key | Type | Description |",
	"| 名称 | 数值 | 说明 |",
}

var mdTableNotes = []string{
	"默认开启", "需要重启", "仅限桌面端", "已弃用", "experimental", "optional", "可选", "必填",
}

var mdCodeTypes = []string{"string", "int", "[]byte", "*Document"}

// markdownUnit writes one block: a heading, a paragraph, a list, a code fence or a table.
func (g *generator) markdownUnit() {
	if g.units == 0 {
		g.ln(0, "# Editor performance baseline")
		g.blank()
		return
	}
	p := g.rng.intn(100)
	switch {
	case p < 10:
		g.mdHeading()
	case p < 55:
		g.mdParagraph()
	case p < 70:
		g.mdList(false)
	case p < 80:
		g.mdList(true)
	case p < 90:
		g.mdCodeFence()
	default:
		g.mdTable()
	}
}

// mdPiece returns a short stretch of prose, under 100 bytes, that mixes Chinese and English and
// uses the inline markup of the format. The bound, together with the 180-byte target of a
// paragraph line, keeps every line under the 300 bytes the shape promises.
func (g *generator) mdPiece() string {
	r := &g.rng
	switch r.intn(9) {
	case 0, 1, 2:
		return r.pick(mdSentences)
	case 3:
		return "The " + r.word() + " of every " + r.word() + " stays in " + r.word() + "."
	case 4:
		return "请先检查 `" + r.camel(2) + "` 的取值。"
	case 5:
		return "**" + r.phrase(2) + "** 是这里最重要的概念。"
	case 6:
		return "详见 [" + r.phrase(2) + "](https://example.com/" + r.word() + "/" + r.word() + ")。"
	case 7:
		return "Use `" + r.camel(1) + "()` to " + r.word() + " the " + r.word() + " before you " + r.word() + " it."
	}
	return capitalize(r.phrase(r.between(4, 8))) + ", *" + r.word() + "* included."
}

// mdHeading writes a heading of level one to three, in English or Chinese.
func (g *generator) mdHeading() {
	r := &g.rng
	level := 3
	if p := r.intn(8); p == 0 {
		level = 1
	} else if p <= 3 {
		level = 2
	}
	text := capitalize(r.phrase(r.between(1, 3)))
	if r.chance(2) {
		text = r.pick(mdHeadings)
	}
	g.ln(0, strings.Repeat("#", level)+" "+text)
	g.blank()
}

// mdParagraph writes a paragraph of one to three lines of 40 to 300 bytes.
func (g *generator) mdParagraph() {
	r := &g.rng
	for range r.between(1, 3) {
		target := r.between(40, 180)
		start := len(g.buf)
		for len(g.buf)-start < target {
			// A space separates English words but not Chinese text, which has none.
			if len(g.buf) > start && g.buf[len(g.buf)-1] < 0x80 {
				g.str(" ")
			}
			g.str(g.mdPiece())
		}
		g.str("\n")
	}
	g.blank()
}

// mdList writes a bullet or numbered list of three to six items.
func (g *generator) mdList(numbered bool) {
	r := &g.rng
	for i, n := 0, r.between(3, 6); i < n; i++ {
		marker := "- "
		if numbered {
			marker = strconv.Itoa(i+1) + ". "
		}
		item := g.mdPiece()
		if r.chance(3) {
			item = "**" + r.phrase(2) + "**: " + item
		}
		g.ln(0, marker+item)
		if !numbered && r.chance(5) {
			g.ln(0, "  - "+g.mdPiece())
		}
	}
	g.blank()
}

// mdCodeFence writes a fenced Go block of three to ten lines.
func (g *generator) mdCodeFence() {
	r := &g.rng
	g.ln(0, "```go")
	g.lnf(0, "func %s(%s %s) error {", r.pascal(2), r.camel(1), r.pick(mdCodeTypes))
	for range r.between(1, 8) {
		switch r.intn(4) {
		case 0:
			g.lnf(1, "%s := %s.%s(%s)", r.camel(1), r.camel(1), r.pascal(1), r.camel(1))
		case 1:
			g.lnf(1, "fmt.Println(%q, %s)", r.word(), r.camel(1))
		case 2:
			g.lnf(1, "defer %s.Close()", r.camel(1))
		default:
			name := r.camel(1)
			g.lnf(1, "%s = append(%s, %s)", name, name, r.camel(1))
		}
	}
	g.ln(0, "}")
	g.ln(0, "```")
	g.blank()
}

// mdTable writes a three-column table of two to four rows.
func (g *generator) mdTable() {
	r := &g.rng
	g.ln(0, r.pick(mdTableHeads))
	g.ln(0, "| --- | --- | --- |")
	for range r.between(2, 4) {
		g.lnf(0, "| `%s` | %d | %s |", r.camel(1), r.intn(1000), r.pick(mdTableNotes))
	}
	g.blank()
}

// Log.

var logLevels = []string{
	"DEBUG", "DEBUG", "DEBUG", "INFO", "INFO", "INFO", "INFO", "INFO", "INFO", "WARN", "WARN", "ERROR",
}

var logComponents = []string{
	"workbench.editor", "workbench.layout", "syntax.textmate", "fs.watcher", "lsp.client",
	"plugin.host", "terminal.pty", "search.index", "vcs.git", "settings.store",
}

var logMethods = []string{
	"textDocument/hover", "textDocument/completion", "textDocument/definition",
	"textDocument/references", "workspace/symbol",
}

var logExts = []string{".go", ".java", ".md", ".json"}

var logExceptions = []string{
	"java.lang.IllegalStateException", "java.io.IOException", "java.lang.NullPointerException",
	"java.util.concurrent.TimeoutException",
}

// logStamp formats a timestamp the way the log of the application does. The zone is written as
// a literal Z because the clock is always UTC.
func logStamp(ms int64) string {
	return time.UnixMilli(ms).UTC().Format("2006-01-02T15:04:05.000") + "Z"
}

// logUnit writes one log line, and after an error sometimes a stack trace. Every line moves the
// clock forward by at least a millisecond, so the timestamps strictly increase.
func (g *generator) logUnit() {
	r := &g.rng
	g.clock += int64(r.between(1, 250))
	level := r.pick(logLevels)
	component := r.pick(logComponents)
	message := g.logMessage(level)
	if r.chance(8) {
		message += " payload=" + g.logPayload()
	}
	g.lnf(0, "%s %-5s [%s] %s", logStamp(g.clock), level, component, message)
	if level == "ERROR" && r.chance(2) {
		g.logTrace()
	}
}

// logPath returns a source path for a message.
func (g *generator) logPath() string {
	r := &g.rng
	return "/src/" + r.word() + "/" + r.word() + r.pick(logExts)
}

// logPayload returns a small inline JSON object.
func (g *generator) logPayload() string {
	r := &g.rng
	return fmt.Sprintf(`{"id":%d,"kind":%q,"ok":%t}`, r.intn(100000), r.word(), r.chance(2))
}

// logMessage returns the message of a line of the given level.
func (g *generator) logMessage(level string) string {
	r := &g.rng
	switch level {
	case "ERROR":
		switch r.intn(3) {
		case 0:
			return fmt.Sprintf("failed to read document path=%s err=%q attempt=%d", g.logPath(), "permission denied", r.between(1, 3))
		case 1:
			return fmt.Sprintf("language server request failed method=%s id=%d err=%q", r.pick(logMethods), r.intn(100000), "request timed out after 30000ms")
		}
		return fmt.Sprintf("plugin host exited unexpectedly plugin=%s code=%d restarts=%d", r.word(), r.between(1, 137), r.between(0, 5))
	case "WARN":
		switch r.intn(3) {
		case 0:
			return fmt.Sprintf("slow frame detected frame=%d budget=16ms actual=%d.%dms", r.intn(100000), r.between(17, 90), r.intn(10))
		case 1:
			return fmt.Sprintf("document is large path=%s bytes=%d, syntax highlighting is deferred", g.logPath(), r.between(1<<20, 1<<26))
		}
		return fmt.Sprintf("watcher queue is filling queued=%d capacity=%d dropped=%d", r.between(500, 4000), 4096, r.intn(50))
	}
	switch r.intn(6) {
	case 0:
		return fmt.Sprintf("opened document path=%s bytes=%d elapsed=%d.%03dms", g.logPath(), r.intn(1<<20), r.intn(50), r.intn(1000))
	case 1:
		return fmt.Sprintf("tokenized lines lines=%d cache_hits=%d elapsed=%d.%03dms", r.between(1, 5000), r.intn(5000), r.intn(20), r.intn(1000))
	case 2:
		return fmt.Sprintf("request completed method=%s id=%d status=%s elapsed=%d.%03dms", r.pick(logMethods), r.intn(100000), r.pick([]string{"ok", "ok", "cancelled"}), r.intn(200), r.intn(1000))
	case 3:
		return fmt.Sprintf("watching directory path=%s events=%d", g.logPath(), r.intn(400))
	case 4:
		return fmt.Sprintf("saved document path=%s bytes=%d encoding=utf-8 eol=%s", g.logPath(), r.intn(1<<20), r.pick([]string{"lf", "crlf"}))
	}
	return fmt.Sprintf("layout updated panes=%d width=%d height=%d scale=%d.%d", r.between(1, 6), r.between(800, 3840), r.between(600, 2160), r.between(1, 3), r.intn(10))
}

// logTrace writes a Java stack trace of three to eight frames, sometimes with a cause.
func (g *generator) logTrace() {
	r := &g.rng
	g.lnf(0, "%s: %s", r.pick(logExceptions), r.phrase(r.between(3, 6)))
	pkg := "com.example." + r.word()
	for range r.between(3, 8) {
		class := r.pascal(r.between(1, 2))
		g.lnf(1, "at %s.%s.%s(%s.java:%d)", pkg, class, r.camel(1), class, r.between(10, 900))
	}
	if r.chance(3) {
		g.lnf(0, "Caused by: %s: %s", r.pick(logExceptions), r.phrase(3))
		g.lnf(1, "... %d more", r.between(3, 30))
	}
}

// Mixed.

// The text the mixed document is made of. The emoji are written as escapes so no source line
// depends on how an editor displays them.
var (
	mixedCJK       = []string{"中文", "日本語", "한국어", "编辑器", "テキスト", "문서", "标签页", "ファイル"}
	mixedFullwidth = []string{"，", "。", "！", "？", "：", "；", "、"}
	mixedEmoji     = []string{
		"\U0001F600",                 // grinning face
		"\U0001F680",                 // rocket
		"\U0001F469\u200D\U0001F4BB", // woman technologist: three code points joined with a ZWJ
	}
	// Letters followed by a combining mark, which an editor must keep in one cluster.
	mixedCombining = []string{"e\u0301", "cafe\u0301", "nai\u0308ve", "re\u0301sume\u0301", "n\u0303"}
)

// mixedUnit writes one line that ends with CRLF: most are 20 to 120 bytes and one in fifty is 300
// to 600. Leading tabs and tabs between words make the column of a character differ from its
// byte offset, as do the multi-byte characters.
func (g *generator) mixedUnit() {
	r := &g.rng
	target := r.between(20, 95)
	if r.chance(50) {
		target = r.between(300, 560)
	}
	if !r.chance(3) {
		for range r.between(1, 4) {
			g.str("\t")
		}
	}
	for words := 0; len(g.buf) < target; words++ {
		if words > 0 {
			if r.chance(8) {
				g.str("\t")
			} else {
				g.str(" ")
			}
		}
		g.str(g.mixedPiece())
	}
	g.str("\r\n")
}

// mixedPiece returns one token of a mixed line: mostly ASCII, with CJK, emoji and combining
// marks among them.
func (g *generator) mixedPiece() string {
	r := &g.rng
	switch r.intn(12) {
	case 0:
		return r.pick(mixedCJK)
	case 1:
		return r.pick(mixedCJK) + r.pick(mixedFullwidth)
	case 2:
		return r.pick(mixedEmoji)
	case 3:
		return r.pick(mixedCombining)
	case 4:
		return "（" + r.pick(mixedCJK) + "）"
	case 5, 6, 7:
		return r.word()
	case 8, 9:
		return r.camel(2)
	}
	return strconv.Itoa(r.intn(10000))
}
