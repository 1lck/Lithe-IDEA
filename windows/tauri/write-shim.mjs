import { writeFileSync } from 'node:fs';
writeFileSync(
  'D:/git/web/Lithe-IDEA/node_modules/.bun/vite-plus@0.2.1+0acbb8d8bceea77f/node_modules/vite-plus/node_modules/.bin/tsgolint.cmd',
  '@echo off\r\nnode "%~dp0..\\oxlint-tsgolint\\bin\\tsgolint.js" %*\r\n',
);
console.log('shim written');
