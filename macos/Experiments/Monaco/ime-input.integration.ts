import { editor as monacoEditor } from "monaco-editor/esm/vs/editor/editor.api.js";
import "../../EditorFrontend/ime-input.css";

const assert = (condition: unknown, message: string) => { if (!condition) throw new Error(message); };

// These cases exercise Monaco's real composition presentation. Native candidate
// selection and WebKit repaint timing still require the macOS input-method run.
export const imeInputCases = [false, true].flatMap(dark => [false, true].map(wallpaper => ({
  name: `IME overlay covers old glyphs in ${dark ? "dark" : "light"} ${wallpaper ? "wallpaper" : "solid"} theme`,
  run() {
    const container = document.createElement("div");
    container.style.cssText = "position:absolute;inset:0;width:800px;height:300px";
    document.body.append(container);
    const theme = `ime-${dark}-${wallpaper}`;
    monacoEditor.defineTheme(theme, {
      base: dark ? "vs-dark" : "vs", inherit: true, rules: [],
      colors: {
        "editor.background": wallpaper ? "#00000000" : dark ? "#202020" : "#ffffff",
        "editor.lineHighlightBackground": dark ? "#ffffff09" : "#00000009",
      },
    });
    const model = monacoEditor.createModel("已有中文 abc", "plaintext");
    const view = monacoEditor.create(container, { model, theme, editContext: false });
    try {
      view.setPosition({ lineNumber: 1, column: 3 });
      view.focus();
      view.render(true);
      const input = container.querySelector<HTMLTextAreaElement>("textarea.inputarea")!;
      assert(input, "Monaco did not create its textarea input");
      const idleBackground = getComputedStyle(input).backgroundColor;
      for (const candidate of ["zhong", "zhon", "中"]) {
        input.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true, data: "" }));
        input.dispatchEvent(new CompositionEvent("compositionupdate", { bubbles: true, data: candidate }));
        assert(input.classList.contains("ime-input"), "composition did not show the input overlay");
        const style = getComputedStyle(input);
        const canvas = document.createElement("canvas");
        const context = canvas.getContext("2d")!;
        context.fillStyle = style.backgroundColor;
        context.fillRect(0, 0, 1, 1);
        assert(context.getImageData(0, 0, 1, 1).data[3] === 255,
          `composition background exposes old line glyphs: ${style.backgroundColor}`);
        assert(style.backgroundImage.includes("linear-gradient"), "composition lost the theme surface layers");
        input.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true, data: candidate }));
        assert(!input.classList.contains("ime-input"), "composition overlay remained after commit");
        assert(getComputedStyle(input).backgroundColor === idleBackground, "IME surface leaked into ordinary input");
      }
    } finally {
      view.dispose();
      model.dispose();
      container.remove();
      monacoEditor.setTheme("lithe-dark");
    }
  },
})));
