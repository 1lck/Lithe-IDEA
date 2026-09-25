import path from "node:path";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { codeInspectorPlugin } from "code-inspector-plugin";
import { defaultExclude, defineConfig } from "vite-plus";

const enableCodeInspector = process.env.VITE_CODE_INSPECTOR === "true";

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [
    enableCodeInspector
      ? codeInspectorPlugin({
          bundler: "vite",
        })
      : null,
    react(),
    tailwindcss(),
  ].filter(Boolean),
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
      "@lithe/v0": path.resolve(__dirname, "../../Plugins/win/Official/V0Support"),
      "@tauri-apps/plugin-http": path.resolve(__dirname, "./node_modules/@tauri-apps/plugin-http"),
      // Keep Zustand's Immer middleware on the ESM path so it shares the app's Immer runtime.
      "zustand/middleware/immer": path.resolve(
        __dirname,
        "./node_modules/zustand/esm/middleware/immer.mjs",
      ),
      "zustand": path.resolve(__dirname, "./node_modules/zustand"),
      // Consume live shared sources; Bun's local file dependency may retain an older copy.
      "@lithe/editor": path.resolve(__dirname, "../../frontend/editor/src"),
    },
    dedupe: ["react", "react-dom", "monaco-editor", "immer"],
  },
  test: {
    testTimeout: 10_000,
    exclude: [
      ...defaultExclude,
      "**/.direnv/**",
      "**/dist/**",
      "**/build/**",
      "**/target/**",
      "**/src-tauri/**",
    ],
  },
  server: {
    port: 1420,
    host: "127.0.0.1",
  },
});
