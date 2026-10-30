/**
 * Redefining the active Monaco theme makes Monaco rebuild every theme CSS rule,
 * recolor all models and announce a theme change, which re-tokenizes every open
 * Java model. Every editor mount defines the current theme, so only changed
 * definitions may reach Monaco.
 */
export class MonacoThemeDefinitionCache {
  private readonly definitions = new Map<string, string>();

  /** Records `data` for `themeName`; returns whether Monaco still needs it. */
  needsDefinition(themeName: string, data: unknown): boolean {
    const serialized = JSON.stringify(data);
    if (this.definitions.get(themeName) === serialized) return false;
    this.definitions.set(themeName, serialized);
    return true;
  }
}
