import { languages } from "monaco-editor/esm/vs/editor/editor.api.js";

/** LSP and Monaco use different numeric completion-kind enumerations. */
export function mapCompletionKind(kind: number | null | undefined): languages.CompletionItemKind {
  const monacoKind = languages.CompletionItemKind;
  switch (kind) {
    case 1:
      return monacoKind.Text;
    case 2:
      return monacoKind.Method;
    case 3:
      return monacoKind.Function;
    case 4:
      return monacoKind.Constructor;
    case 5:
      return monacoKind.Field;
    case 6:
      return monacoKind.Variable;
    case 7:
      return monacoKind.Class;
    case 8:
      return monacoKind.Interface;
    case 9:
      return monacoKind.Module;
    case 10:
      return monacoKind.Property;
    case 11:
      return monacoKind.Unit;
    case 12:
      return monacoKind.Value;
    case 13:
      return monacoKind.Enum;
    case 14:
      return monacoKind.Keyword;
    case 15:
      return monacoKind.Snippet;
    case 16:
      return monacoKind.Color;
    case 17:
      return monacoKind.File;
    case 18:
      return monacoKind.Reference;
    case 19:
      return monacoKind.Folder;
    case 20:
      return monacoKind.EnumMember;
    case 21:
      return monacoKind.Constant;
    case 22:
      return monacoKind.Struct;
    case 23:
      return monacoKind.Event;
    case 24:
      return monacoKind.Operator;
    case 25:
      return monacoKind.TypeParameter;
    default:
      return monacoKind.Text;
  }
}
