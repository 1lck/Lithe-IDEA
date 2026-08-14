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
    },
    dedupe: ["react", "react-dom"],
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
