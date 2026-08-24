export interface MonacoLanguageModel {
  getLanguageId(): string;
  isDisposed(): boolean;
}

/**
 * Reapplies a model language after its lazily loaded tokenizer is registered.
 *
 * Monaco notices provider registration in normal circumstances, but a cached
 * model created before the provider exists can remain in plaintext state. A
 * temporary public-language transition reliably rebuilds tokenization without
 * reaching into Monaco's private model internals.
 */
export function reactivateMonacoModelLanguage(
  model: MonacoLanguageModel,
  languageId: string,
  setModelLanguage: (model: MonacoLanguageModel, languageId: string) => void,
): boolean {
  if (model.isDisposed() || model.getLanguageId() !== languageId) return false;

  setModelLanguage(model, "plaintext");
  if (model.isDisposed()) return false;
  setModelLanguage(model, languageId);
  return true;
}
