// Narrow declarations for the private tokenization APIs in pinned Monaco 0.55.1.
// Keep these with the shared adapter so both platform builds check the same boundary.
declare module "monaco-editor/esm/vs/editor/common/languages.js" {
  import type { IDisposable, editor, languages } from "monaco-editor";
  export class Token {
    constructor(offset: number, type: string, language: string);
    offset: number;
    type: string;
    language: string;
  }
  export class TokenizationResult {
    constructor(tokens: Token[], endState: languages.IState);
    tokens: Token[];
    endState: languages.IState;
  }
  export class EncodedTokenizationResult {
    constructor(tokens: Uint32Array, endState: languages.IState);
    tokens: Uint32Array;
    endState: languages.IState;
  }
  export interface BackgroundTokenStore {
    setEndState(lineNumber: number, state: languages.IState): void;
    setTokens(tokens: readonly unknown[]): void;
    backgroundTokenizationFinished(): void;
  }
  export const TokenizationRegistry: {
    handleChange(languages: string[]): void;
    register(language: string, support: {
      getInitialState(): languages.IState;
      tokenize(line: string, hasEOL: boolean, state: languages.IState): TokenizationResult;
      tokenizeEncoded(line: string, hasEOL: boolean, state: languages.IState): EncodedTokenizationResult;
      createBackgroundTokenizer(model: editor.ITextModel, store: BackgroundTokenStore):
        (IDisposable & { requestTokens(startLine: number, endLineExclusive: number): void }) | undefined;
    }): IDisposable;
  };
}

declare module "monaco-editor/esm/vs/editor/common/tokens/contiguousMultilineTokensBuilder.js" {
  export class ContiguousMultilineTokensBuilder {
    add(lineNumber: number, lineTokens: Uint32Array): void;
    finalize(): readonly unknown[];
  }
}

declare module "monaco-editor/esm/vs/editor/standalone/browser/standaloneServices.js" {
  export interface ServiceIdentifier<T> { readonly type: T }
  export const StandaloneServices: { get<T>(id: ServiceIdentifier<T>): T };
}

declare module "monaco-editor/esm/vs/editor/standalone/common/standaloneTheme.js" {
  import type { IDisposable } from "monaco-editor";
  import type { ServiceIdentifier } from "monaco-editor/esm/vs/editor/standalone/browser/standaloneServices.js";
  export const IStandaloneThemeService: ServiceIdentifier<{
    getColorTheme(): { tokenTheme: { match(languageID: number, token: string): number } };
    onDidColorThemeChange(listener: () => void): IDisposable;
  }>;
}

declare module "monaco-editor/esm/vs/editor/common/languages/language.js" {
  import type { ServiceIdentifier } from "monaco-editor/esm/vs/editor/standalone/browser/standaloneServices.js";
  export const ILanguageService: ServiceIdentifier<{
    languageIdCodec: { encodeLanguageId(language: string): number };
  }>;
}
