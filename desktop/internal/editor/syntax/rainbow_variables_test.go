package syntax

import (
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
)

func TestRainbowCandidatesVariablesFromTextMate(t *testing.T) {
	registry := NewRegistry()
	for _, tc := range []struct{ language, annotated string }{
		{"go", "package main\nfunc run(«seed» int) int {\r\n «counter» := «seed»\n var «person» Example\n _ = `counter 😀`\n return «person».counter + counter() + «counter» // counter\n}"},
		{"java", "class Example { int run(int «seed») {\n int «counter» = «seed»;\n String «text» = \"counter 😀\"; int «total» = «counter»;\n return «total» + «thing».counter + counter() + «counter»; // counter\n } }"},
		{"javascript", "function run(«seed») {\n let «counter» = «seed»;\n const «text» = `counter ${«counter»} 😀`;\n return «counter» + «obj».counter + counter() + /counter/.source; // counter\n}"},
		{"typescript", "function run(«seed»: Value): Value {\n const «counter»: Value = «seed»;\n return «counter» + «obj»?.counter + counter(); // counter\n}"},
		{"rust", "fn run(«seed»: i32) -> i32 {\n let mut «counter» = «seed»;\n let «text» = r#\"counter 😀\"#;\n «counter» += «obj».counter + counter(); // counter\n «counter»\n}"},
	} {
		t.Run(tc.language, func(t *testing.T) {
			assertRainbowVariableRanges(t, registry.Syntax(tc.language), tc.annotated)
		})
	}
}

func TestRainbowCandidatesRustRawIdentifiersPreserveSourceSpelling(t *testing.T) {
	assertRainbowVariableRanges(t, NewRegistry().Syntax("rust"), `fn main() {
    let «r#type» = 1;
    let «r#match» = «r#type»;
    let «value» = «r#match»;
    let «r#value» = «value»;
    consume(«r#type», «r#value», «value»);
    let «text» = r#"r#type and r#value"#;
    // r#type and r#value stay in the comment's style.
}`)
}

func TestRainbowCandidatesJavaVariablesInBranches(t *testing.T) {
	java := NewRegistry().Syntax("java")
	t.Run("ternary", func(t *testing.T) {
		assertRainbowVariableRanges(t, java, `class StrategyService {
    Long resolveStrategyId(Long «strategyVersionId») {
        StrategyVersion «version» = «strategyVersionMapper».selectById(«strategyVersionId»);
        return «version» == null ? null : «version».getStrategyId();
    }
}`)
	})
	t.Run("assignments and arguments", func(t *testing.T) {
		assertRainbowVariableRanges(t, java, `class Service {
    private Long extractLong(Object «target», String «fieldName») {
        if («target» == null) {
            return null;
        }
        Object «value»;
        if («target» instanceof Map<?, ?> «map») {
            «value» = «map».get(«fieldName»);
        } else {
            try {
                «value» = ReflectUtil.getFieldValue(«target», «fieldName»);
            } catch (Exception «e») {
                return null;
            }
        }
        return «value» == null ? null : Long.valueOf(«value».toString()); // value 😀
    }
}`)
	})
}

func assertRainbowVariableRanges(t *testing.T, language *Syntax, annotated string) {
	t.Helper()
	if language == nil {
		t.Fatal("expected a bundled grammar")
	}
	var source strings.Builder
	var want []Variable
	for remaining := annotated; remaining != ""; {
		before, marked, found := strings.Cut(remaining, "«")
		source.WriteString(before)
		if !found {
			break
		}
		name, rest, closed := strings.Cut(marked, "»")
		if !closed {
			t.Fatal("unclosed variable marker in fixture")
		}
		start := uint32(source.Len())
		source.WriteString(name)
		want = append(want, Variable{Start: start, End: uint32(source.Len()), Name: name})
		remaining = rest
	}
	text := rope.FromString(source.String())
	brackets, got := RainbowCandidates(t.Context(), text, language, true, true)
	if wantBrackets := RainbowBrackets(t.Context(), text, language); len(wantBrackets) == 0 || !slices.Equal(brackets, wantBrackets) {
		t.Fatalf("combined scan returned brackets %v, want %v", brackets, wantBrackets)
	}
	if !slices.Equal(got, want) {
		t.Fatalf("got variables %v, want %v", got, want)
	}
}
