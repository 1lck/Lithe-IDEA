/** Compatibility entrypoint; all installable language packages contain signed resources. */
process.argv[2] ??= "PhpSupport";
await import("./build-windows-language-plugin");
export {};
