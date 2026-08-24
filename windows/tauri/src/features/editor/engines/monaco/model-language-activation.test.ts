import { describe, expect, mock, test } from "bun:test";
import { reactivateMonacoModelLanguage } from "./model-language-activation";
import { toMonacoLanguageId } from "./language";

describe("Monaco model language activation", () => {
  test("forces a tokenizer rebuild through public language transitions", () => {
    let languageId = "java";
    const model = {
      getLanguageId: () => languageId,
      isDisposed: () => false,
    };
    const setModelLanguage = mock((_model: typeof model, nextLanguageId: string) => {
      languageId = nextLanguageId;
    });

    expect(reactivateMonacoModelLanguage(model, "java", setModelLanguage)).toBe(true);
    expect(setModelLanguage).toHaveBeenNthCalledWith(1, model, "plaintext");
    expect(setModelLanguage).toHaveBeenNthCalledWith(2, model, "java");
  });

  test("does not overwrite a model that changed language or was disposed", () => {
    const setModelLanguage = mock(() => undefined);

    expect(
      reactivateMonacoModelLanguage(
        { getLanguageId: () => "kotlin", isDisposed: () => false },
        "java",
        setModelLanguage,
      ),
    ).toBe(false);
    expect(
      reactivateMonacoModelLanguage(
        { getLanguageId: () => "java", isDisposed: () => true },
        "java",
        setModelLanguage,
      ),
    ).toBe(false);
    expect(setModelLanguage).not.toHaveBeenCalled();
  });

  test("maps the product plain-text id to Monaco's registered id", () => {
    expect(toMonacoLanguageId("text")).toBe("plaintext");
  });
});
