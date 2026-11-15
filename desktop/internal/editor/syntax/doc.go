// Package syntax colors text for the editor: which language a file is, how its TextMate scopes
// become theme tokens, how a color scheme styles those tokens, and an incremental highlighter
// that keeps a document's colors current as it is edited.
//
// The pieces and how they connect:
//
//   - A Language names a grammar and the Rules that turn the grammar's scope stacks into token
//     Names such as "keyword.java" or "comment.documentation". The Registry holds the bundled
//     languages and the ones plugins add, and picks one for a path.
//   - A Theme maps a Name to a Style with Monaco's token theme semantics: the longest dotted
//     prefix of the name that has a rule wins. Scheme builds the editor's themes from the
//     bundled color schemes the way the previous editor did, so colors match it.
//   - A Highlighter tokenizes one document. It keeps tokenizer states only at checkpoints and
//     tokens only for the lines the view has asked for recently; every other line is computed
//     when needed and not kept, which keeps memory and garbage-collector work flat in the size
//     of the file.
//   - Semantic tokens from a language server are an overlay on a Highlighter, replacing the
//     lexical style of the ranges they cover.
//
// Nothing here writes to disk.
package syntax
