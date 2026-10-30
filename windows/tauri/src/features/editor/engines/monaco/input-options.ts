import type * as Monaco from "monaco-editor";

/**
 * Input options shared by every Monaco editor Lithe creates.
 *
 * Monaco's EditContext input reads the editor's on-screen bounds after every
 * render so the IME knows where the caret is. Each read forces a synchronous
 * style and layout pass, and every mounted editor (hidden tabs included)
 * renders when language-server decorations arrive, so jumping between classes
 * paid several whole-window layouts per frame. The textarea input Monaco used
 * before positions its hidden textarea without reading layout, supports IME
 * composition, and is what Lithe's keyboard routing already expects
 * (`textarea.inputarea`).
 */
export const MONACO_INPUT_OPTIONS = {
  editContext: false,
} as const satisfies Monaco.editor.IEditorOptions;
