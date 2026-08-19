import { useMemo, useRef, useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { useShallow } from "zustand/react/shallow";
import { getAllLanguages } from "@/features/editor/utils/language-id";
import { validateJavaLspJavaHome } from "@/features/editor/lsp/java-lsp-host-api";
import { getDefaultSetting, useSettingsStore } from "@/features/settings/stores/settings.store";
import { useToast } from "@/features/layout/contexts/toast-context";
import { Button } from "@/ui/button";
import { ButtonGroup } from "@/ui/button-group";
import Input from "@/ui/input";
import { FolderIcon } from "@/ui/icons";
import NumberInput from "@/ui/number-input";
import Section, { SETTINGS_CONTROL_WIDTHS, SettingsView, SettingRow } from "../settings-section";
import Select from "@/ui/select";
import Switch from "@/ui/switch";
import { FontSelector } from "../font-selector";
import { useTranslation } from "@/i18n/locale-provider";

export const EditorSettings = () => {
  const { t } = useTranslation();
  const { showToast } = useToast();
  const [isValidatingJdtlsJdk, setIsValidatingJdtlsJdk] = useState(false);
  const jdtlsJdkRequest = useRef(0);
  const settings = useSettingsStore(
    useShallow((state) => ({
      autoCompletion: state.settings.autoCompletion,
      autoDetectLanguage: state.settings.autoDetectLanguage,
      autoSave: state.settings.autoSave,
      breadcrumbShowSymbols: state.settings.breadcrumbShowSymbols,
      defaultLanguage: state.settings.defaultLanguage,
      editorBracketPairColorization: state.settings.editorBracketPairColorization,
      editorCursorBlinking: state.settings.editorCursorBlinking,
      editorCursorStyle: state.settings.editorCursorStyle,
      editorFontLigatures: state.settings.editorFontLigatures,
      editorItalicComments: state.settings.editorItalicComments,
      editorLineHeight: state.settings.editorLineHeight,
      editorScrollBeyondLastLine: state.settings.editorScrollBeyondLastLine,
      editorSmoothScrolling: state.settings.editorSmoothScrolling,
      editorStickyScroll: state.settings.editorStickyScroll,
      fontFamily: state.settings.fontFamily,
      fontSize: state.settings.fontSize,
      formatOnSave: state.settings.formatOnSave,
      highlightOccurrences: state.settings.highlightOccurrences,
      horizontalTabScroll: state.settings.horizontalTabScroll,
      codeLens: state.settings.codeLens,
      inlayHints: state.settings.inlayHints,
      jdtlsJavaHomePath: state.settings.jdtlsJavaHomePath,
      lineNumbers: state.settings.lineNumbers,
      lintOnSave: state.settings.lintOnSave,
      maxOpenTabs: state.settings.maxOpenTabs,
      parameterHints: state.settings.parameterHints,
      renderIndentGuides: state.settings.renderIndentGuides,
      renderWhitespace: state.settings.renderWhitespace,
      semanticTokens: state.settings.semanticTokens,
      showMinimap: state.settings.showMinimap,
      tabSize: state.settings.tabSize,
      vimRelativeLineNumbers: state.settings.vimRelativeLineNumbers,
      wordWrap: state.settings.wordWrap,
    })),
  );
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);
  const languageOptions = useMemo(
    () => [
      { value: "auto", label: t("settings.editor.autoDetect") },
      ...getAllLanguages().map((language) => ({
        value: language.id,
        label: language.displayName,
      })),
    ],
    [t],
  );
  const renderWhitespaceOptions = [
    { value: "none", label: t("settings.editor.whitespaceNone") },
    { value: "boundary", label: t("settings.editor.whitespaceBoundary") },
    { value: "trailing", label: t("settings.editor.whitespaceTrailing") },
    { value: "all", label: t("settings.editor.whitespaceAll") },
  ];
  const usesAutomaticJdtlsJdk = settings.jdtlsJavaHomePath.length === 0;

  const applyJdtlsJavaHomePath = async (javaHomePath: string) => {
    if (settings.jdtlsJavaHomePath === javaHomePath) return;

    await updateSetting("jdtlsJavaHomePath", javaHomePath);
    try {
      const { LspClient } = await import("@/features/editor/lsp/lsp-client");
      const client = LspClient.getInstance();
      const javaServers = client
        .getActiveServerEntries()
        .filter((entry) => entry.languageId === "java");
      await Promise.all(javaServers.map((entry) => client.restartTrackedServer(entry.key)));
    } catch (error) {
      console.error("Failed to restart Java language server after JDK change:", error);
    }
  };

  const useAutomaticJdtlsJdk = () => {
    jdtlsJdkRequest.current += 1;
    setIsValidatingJdtlsJdk(false);
    void applyJdtlsJavaHomePath("");
  };

  const chooseJdtlsJdk = async () => {
    const request = ++jdtlsJdkRequest.current;
    setIsValidatingJdtlsJdk(true);

    try {
      const selected = await open({ directory: true, multiple: false });
      if (request !== jdtlsJdkRequest.current || typeof selected !== "string" || !selected) return;

      const runtime = await validateJavaLspJavaHome(selected);
      if (request !== jdtlsJdkRequest.current) return;

      await applyJdtlsJavaHomePath(runtime.homePath);
      if (request !== jdtlsJdkRequest.current) return;

      showToast({
        message: t("settings.editor.jdtlsJdkSelected", { version: runtime.version }),
        type: "success",
      });
    } catch (error) {
      if (request !== jdtlsJdkRequest.current) return;

      showToast({
        message: t("settings.editor.jdtlsJdkInvalid", { error: String(error) }),
        type: "error",
      });
    } finally {
      if (request === jdtlsJdkRequest.current) setIsValidatingJdtlsJdk(false);
    }
  };

  return (
    <SettingsView>
      <Section title={t("settings.editor.section")}>
        <SettingRow
          label={t("settings.editor.fontFamily")}
          description={t("settings.editor.fontFamilyDescription")}
          onReset={() => updateSetting("fontFamily", getDefaultSetting("fontFamily"))}
          canReset={settings.fontFamily !== getDefaultSetting("fontFamily")}
        >
          <FontSelector
            value={settings.fontFamily}
            onChange={(fontFamily) => updateSetting("fontFamily", fontFamily)}
            className={SETTINGS_CONTROL_WIDTHS.text}
            monospaceOnly={true}
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.fontSize")}
          description={t("settings.editor.fontSizeDescription")}
          onReset={() => updateSetting("fontSize", getDefaultSetting("fontSize"))}
          canReset={settings.fontSize !== getDefaultSetting("fontSize")}
        >
          <NumberInput
            min="8"
            max="32"
            value={settings.fontSize}
            onChange={(val) => updateSetting("fontSize", val)}
            className={SETTINGS_CONTROL_WIDTHS.numberCompact}
            size="md"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.fontLigatures")}
          description={t("settings.editor.fontLigaturesDescription")}
          onReset={() =>
            updateSetting("editorFontLigatures", getDefaultSetting("editorFontLigatures"))
          }
          canReset={settings.editorFontLigatures !== getDefaultSetting("editorFontLigatures")}
        >
          <Switch
            checked={settings.editorFontLigatures}
            onChange={(checked) => updateSetting("editorFontLigatures", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.italicComments")}
          description={t("settings.editor.italicCommentsDescription")}
          onReset={() =>
            updateSetting("editorItalicComments", getDefaultSetting("editorItalicComments"))
          }
          canReset={settings.editorItalicComments !== getDefaultSetting("editorItalicComments")}
        >
          <Switch
            checked={settings.editorItalicComments}
            onChange={(checked) => updateSetting("editorItalicComments", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.lineHeight")}
          description={t("settings.editor.lineHeightDescription")}
          onReset={() => updateSetting("editorLineHeight", getDefaultSetting("editorLineHeight"))}
          canReset={settings.editorLineHeight !== getDefaultSetting("editorLineHeight")}
        >
          <NumberInput
            min="1"
            max="2"
            step={0.1}
            value={settings.editorLineHeight}
            onChange={(val) => updateSetting("editorLineHeight", val)}
            className={SETTINGS_CONTROL_WIDTHS.numberCompact}
            size="md"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.tabSize")}
          description={t("settings.editor.tabSizeDescription")}
          onReset={() => updateSetting("tabSize", getDefaultSetting("tabSize"))}
          canReset={settings.tabSize !== getDefaultSetting("tabSize")}
        >
          <NumberInput
            min="1"
            max="8"
            value={settings.tabSize}
            onChange={(val) => updateSetting("tabSize", val)}
            className={SETTINGS_CONTROL_WIDTHS.numberCompact}
            size="md"
          />
        </SettingRow>
        <SettingRow
          label={t("settings.editor.wordWrap")}
          description={t("settings.editor.wordWrapDescription")}
          onReset={() => updateSetting("wordWrap", getDefaultSetting("wordWrap"))}
          canReset={settings.wordWrap !== getDefaultSetting("wordWrap")}
        >
          <Switch
            checked={settings.wordWrap}
            onChange={(checked) => updateSetting("wordWrap", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.lineNumbers")}
          description={t("settings.editor.lineNumbersDescription")}
          onReset={() => updateSetting("lineNumbers", getDefaultSetting("lineNumbers"))}
          canReset={settings.lineNumbers !== getDefaultSetting("lineNumbers")}
        >
          <Switch
            checked={settings.lineNumbers}
            onChange={(checked) => updateSetting("lineNumbers", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.renderWhitespace")}
          description={t("settings.editor.renderWhitespaceDescription")}
          onReset={() => updateSetting("renderWhitespace", getDefaultSetting("renderWhitespace"))}
          canReset={settings.renderWhitespace !== getDefaultSetting("renderWhitespace")}
        >
          <Select
            value={settings.renderWhitespace}
            options={renderWhitespaceOptions}
            onChange={(value) =>
              updateSetting("renderWhitespace", value as typeof settings.renderWhitespace)
            }
            className={SETTINGS_CONTROL_WIDTHS.default}
            size="md"
            variant="default"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.indentGuides")}
          description={t("settings.editor.indentGuidesDescription")}
          onReset={() =>
            updateSetting("renderIndentGuides", getDefaultSetting("renderIndentGuides"))
          }
          canReset={settings.renderIndentGuides !== getDefaultSetting("renderIndentGuides")}
        >
          <Switch
            checked={settings.renderIndentGuides}
            onChange={(checked) => updateSetting("renderIndentGuides", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.highlightOccurrences")}
          description={t("settings.editor.highlightOccurrencesDescription")}
          onReset={() =>
            updateSetting("highlightOccurrences", getDefaultSetting("highlightOccurrences"))
          }
          canReset={settings.highlightOccurrences !== getDefaultSetting("highlightOccurrences")}
        >
          <Switch
            checked={settings.highlightOccurrences}
            onChange={(checked) => updateSetting("highlightOccurrences", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.relativeLineNumbers")}
          description={t("settings.editor.relativeLineNumbersDescription")}
          onReset={() =>
            updateSetting("vimRelativeLineNumbers", getDefaultSetting("vimRelativeLineNumbers"))
          }
          canReset={settings.vimRelativeLineNumbers !== getDefaultSetting("vimRelativeLineNumbers")}
        >
          <Switch
            checked={settings.vimRelativeLineNumbers}
            onChange={(checked) => updateSetting("vimRelativeLineNumbers", checked)}
            size="sm"
            disabled={!settings.lineNumbers}
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.showMinimap")}
          description={t("settings.editor.showMinimapDescription")}
          onReset={() => updateSetting("showMinimap", getDefaultSetting("showMinimap"))}
          canReset={settings.showMinimap !== getDefaultSetting("showMinimap")}
        >
          <Switch
            checked={settings.showMinimap}
            onChange={(checked) => updateSetting("showMinimap", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.stickyScroll")}
          description={t("settings.editor.stickyScrollDescription")}
          onReset={() =>
            updateSetting("editorStickyScroll", getDefaultSetting("editorStickyScroll"))
          }
          canReset={settings.editorStickyScroll !== getDefaultSetting("editorStickyScroll")}
        >
          <Switch
            checked={settings.editorStickyScroll}
            onChange={(checked) => updateSetting("editorStickyScroll", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.bracketPairColorization")}
          description={t("settings.editor.bracketPairColorizationDescription")}
          onReset={() =>
            updateSetting(
              "editorBracketPairColorization",
              getDefaultSetting("editorBracketPairColorization"),
            )
          }
          canReset={
            settings.editorBracketPairColorization !==
            getDefaultSetting("editorBracketPairColorization")
          }
        >
          <Switch
            checked={settings.editorBracketPairColorization}
            onChange={(checked) => updateSetting("editorBracketPairColorization", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.smoothScrolling")}
          description={t("settings.editor.smoothScrollingDescription")}
          onReset={() =>
            updateSetting("editorSmoothScrolling", getDefaultSetting("editorSmoothScrolling"))
          }
          canReset={settings.editorSmoothScrolling !== getDefaultSetting("editorSmoothScrolling")}
        >
          <Switch
            checked={settings.editorSmoothScrolling}
            onChange={(checked) => updateSetting("editorSmoothScrolling", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.scrollBeyondLastLine")}
          description={t("settings.editor.scrollBeyondLastLineDescription")}
          onReset={() =>
            updateSetting(
              "editorScrollBeyondLastLine",
              getDefaultSetting("editorScrollBeyondLastLine"),
            )
          }
          canReset={
            settings.editorScrollBeyondLastLine !== getDefaultSetting("editorScrollBeyondLastLine")
          }
        >
          <Switch
            checked={settings.editorScrollBeyondLastLine}
            onChange={(checked) => updateSetting("editorScrollBeyondLastLine", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.cursorStyle")}
          description={t("settings.editor.cursorStyleDescription")}
          onReset={() => updateSetting("editorCursorStyle", getDefaultSetting("editorCursorStyle"))}
          canReset={settings.editorCursorStyle !== getDefaultSetting("editorCursorStyle")}
        >
          <Select
            value={settings.editorCursorStyle}
            options={[
              { value: "line", label: t("settings.editor.cursorLine") },
              { value: "line-thin", label: t("settings.editor.cursorThinLine") },
              { value: "block", label: t("settings.editor.cursorBlock") },
              { value: "block-outline", label: t("settings.editor.cursorBlockOutline") },
              { value: "underline", label: t("settings.editor.cursorUnderline") },
              { value: "underline-thin", label: t("settings.editor.cursorThinUnderline") },
            ]}
            onChange={(value) =>
              updateSetting("editorCursorStyle", value as typeof settings.editorCursorStyle)
            }
            className={SETTINGS_CONTROL_WIDTHS.default}
            size="md"
            variant="default"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.cursorBlinking")}
          description={t("settings.editor.cursorBlinkingDescription")}
          onReset={() =>
            updateSetting("editorCursorBlinking", getDefaultSetting("editorCursorBlinking"))
          }
          canReset={settings.editorCursorBlinking !== getDefaultSetting("editorCursorBlinking")}
        >
          <Select
            value={settings.editorCursorBlinking}
            options={[
              { value: "blink", label: t("settings.editor.blink") },
              { value: "smooth", label: t("settings.editor.smooth") },
              { value: "phase", label: t("settings.editor.phase") },
              { value: "expand", label: t("settings.editor.expand") },
              { value: "solid", label: t("settings.editor.solid") },
            ]}
            onChange={(value) =>
              updateSetting("editorCursorBlinking", value as typeof settings.editorCursorBlinking)
            }
            className={SETTINGS_CONTROL_WIDTHS.default}
            size="md"
            variant="default"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.maxOpenTabs")}
          description={t("settings.editor.maxOpenTabsDescription")}
          onReset={() => updateSetting("maxOpenTabs", getDefaultSetting("maxOpenTabs"))}
          canReset={settings.maxOpenTabs !== getDefaultSetting("maxOpenTabs")}
        >
          <NumberInput
            min="1"
            max="100"
            value={settings.maxOpenTabs}
            onChange={(val) => updateSetting("maxOpenTabs", val)}
            className={SETTINGS_CONTROL_WIDTHS.numberCompact}
            size="md"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.bufferCarousel")}
          description={t("settings.editor.bufferCarouselDescription")}
          onReset={() =>
            updateSetting("horizontalTabScroll", getDefaultSetting("horizontalTabScroll"))
          }
          canReset={settings.horizontalTabScroll !== getDefaultSetting("horizontalTabScroll")}
        >
          <Switch
            checked={settings.horizontalTabScroll}
            onChange={(checked) => updateSetting("horizontalTabScroll", checked)}
            size="sm"
          />
        </SettingRow>
        <SettingRow
          label={t("settings.editor.autoSave")}
          description={t("settings.editor.autoSaveDescription")}
          onReset={() => updateSetting("autoSave", getDefaultSetting("autoSave"))}
          canReset={settings.autoSave !== getDefaultSetting("autoSave")}
        >
          <Switch
            checked={settings.autoSave}
            onChange={(checked) => updateSetting("autoSave", checked)}
            size="sm"
          />
        </SettingRow>
        <SettingRow
          label={t("settings.editor.defaultLanguage")}
          description={t("settings.editor.defaultLanguageDescription")}
          onReset={() => updateSetting("defaultLanguage", getDefaultSetting("defaultLanguage"))}
          canReset={settings.defaultLanguage !== getDefaultSetting("defaultLanguage")}
        >
          <Select
            value={settings.defaultLanguage}
            options={languageOptions}
            onChange={(value) => updateSetting("defaultLanguage", value)}
            className={SETTINGS_CONTROL_WIDTHS.default}
            size="md"
            variant="default"
            searchable
            searchableTrigger="input"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.autoDetectLanguage")}
          description={t("settings.editor.autoDetectLanguageDescription")}
          onReset={() =>
            updateSetting("autoDetectLanguage", getDefaultSetting("autoDetectLanguage"))
          }
          canReset={settings.autoDetectLanguage !== getDefaultSetting("autoDetectLanguage")}
        >
          <Switch
            checked={settings.autoDetectLanguage}
            onChange={(checked) => updateSetting("autoDetectLanguage", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.formatOnSave")}
          description={t("settings.editor.formatOnSaveDescription")}
          onReset={() => updateSetting("formatOnSave", getDefaultSetting("formatOnSave"))}
          canReset={settings.formatOnSave !== getDefaultSetting("formatOnSave")}
        >
          <Switch
            checked={settings.formatOnSave}
            onChange={(checked) => updateSetting("formatOnSave", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.lintOnSave")}
          description={t("settings.editor.lintOnSaveDescription")}
          onReset={() => updateSetting("lintOnSave", getDefaultSetting("lintOnSave"))}
          canReset={settings.lintOnSave !== getDefaultSetting("lintOnSave")}
        >
          <Switch
            checked={settings.lintOnSave}
            onChange={(checked) => updateSetting("lintOnSave", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.autoCompletion")}
          description={t("settings.editor.autoCompletionDescription")}
          onReset={() => updateSetting("autoCompletion", getDefaultSetting("autoCompletion"))}
          canReset={settings.autoCompletion !== getDefaultSetting("autoCompletion")}
        >
          <Switch
            checked={settings.autoCompletion}
            onChange={(checked) => updateSetting("autoCompletion", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.parameterHints")}
          description={t("settings.editor.parameterHintsDescription")}
          onReset={() => updateSetting("parameterHints", getDefaultSetting("parameterHints"))}
          canReset={settings.parameterHints !== getDefaultSetting("parameterHints")}
        >
          <Switch
            checked={settings.parameterHints}
            onChange={(checked) => updateSetting("parameterHints", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.inlayHints")}
          description={t("settings.editor.inlayHintsDescription")}
          onReset={() => updateSetting("inlayHints", getDefaultSetting("inlayHints"))}
          canReset={settings.inlayHints !== getDefaultSetting("inlayHints")}
        >
          <Switch
            checked={settings.inlayHints}
            onChange={(checked) => updateSetting("inlayHints", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.codeLens")}
          description={t("settings.editor.codeLensDescription")}
          onReset={() => updateSetting("codeLens", getDefaultSetting("codeLens"))}
          canReset={settings.codeLens !== getDefaultSetting("codeLens")}
        >
          <Switch
            checked={settings.codeLens}
            onChange={(checked) => updateSetting("codeLens", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.semanticTokens")}
          description={t("settings.editor.semanticTokensDescription")}
          onReset={() => updateSetting("semanticTokens", getDefaultSetting("semanticTokens"))}
          canReset={settings.semanticTokens !== getDefaultSetting("semanticTokens")}
        >
          <Switch
            checked={settings.semanticTokens}
            onChange={(checked) => updateSetting("semanticTokens", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.editor.symbolBreadcrumb")}
          description={t("settings.editor.symbolBreadcrumbDescription")}
          onReset={() =>
            updateSetting("breadcrumbShowSymbols", getDefaultSetting("breadcrumbShowSymbols"))
          }
          canReset={settings.breadcrumbShowSymbols !== getDefaultSetting("breadcrumbShowSymbols")}
        >
          <Switch
            checked={settings.breadcrumbShowSymbols}
            onChange={(checked) => updateSetting("breadcrumbShowSymbols", checked)}
            size="sm"
          />
        </SettingRow>
      </Section>
      <Section
        title={t("settings.editor.jdtlsSection")}
        description={t("settings.editor.jdtlsSectionDescription")}
      >
        <SettingRow
          label={t("settings.editor.jdtlsJdk")}
          description={t("settings.editor.jdtlsJdkDescription")}
          onReset={useAutomaticJdtlsJdk}
          canReset={!usesAutomaticJdtlsJdk}
        >
          <div className="w-56 max-w-full space-y-2">
            <ButtonGroup className="w-full" aria-label={t("settings.editor.jdtlsJdkMode")}>
              <Button
                type="button"
                size="sm"
                variant={usesAutomaticJdtlsJdk ? "accent" : "ghost"}
                active={usesAutomaticJdtlsJdk}
                aria-pressed={usesAutomaticJdtlsJdk}
                className="min-w-0 flex-1"
                onClick={useAutomaticJdtlsJdk}
              >
                {t("settings.editor.jdtlsJdkAutomatic")}
              </Button>
              <Button
                type="button"
                size="sm"
                variant={usesAutomaticJdtlsJdk ? "ghost" : "accent"}
                active={!usesAutomaticJdtlsJdk}
                aria-pressed={!usesAutomaticJdtlsJdk}
                className="min-w-0 flex-1"
                disabled={isValidatingJdtlsJdk}
                onClick={() => void chooseJdtlsJdk()}
              >
                {t("settings.editor.jdtlsJdkManual")}
              </Button>
            </ButtonGroup>
            {!usesAutomaticJdtlsJdk ? (
              <div className="flex min-w-0 gap-1.5">
                <Input
                  value={settings.jdtlsJavaHomePath}
                  readOnly
                  className="min-w-0 flex-1 font-mono"
                  aria-label={t("settings.editor.jdtlsJdkPath")}
                />
                <Button
                  type="button"
                  variant="ghost"
                  size="icon-sm"
                  tooltip={t("settings.editor.jdtlsJdkChoose")}
                  disabled={isValidatingJdtlsJdk}
                  onClick={() => void chooseJdtlsJdk()}
                >
                  <FolderIcon />
                </Button>
              </div>
            ) : null}
          </div>
        </SettingRow>
      </Section>
    </SettingsView>
  );
};
