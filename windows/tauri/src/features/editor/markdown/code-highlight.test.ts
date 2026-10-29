import { describe, expect, test } from "bun:test";
import { highlightMarkdownCodeBlocks } from "./code-highlight";

const block = (language: string, code: string) =>
  `<pre><code class="language-${language}">${code}</code></pre>`;

describe("markdown code block highlighting", () => {
  test("keeps replacement patterns in code literally", async () => {
    // The parser hands over escaped HTML, so `$&` arrives as `$&amp;`.
    const code = "select '$&amp;' as a, '$1' as b, '$`' as c from t";
    const html = await highlightMarkdownCodeBlocks(`<p>intro</p>\n${block("sql", code)}`);

    const text = html.replace(/<[^>]+>/g, "");
    expect(text).toBe(`intro\n${code}`);
    expect(html).toContain('<span class="token-keyword">select</span>');
  });

  test("highlights every block in place and leaves unknown languages untouched", async () => {
    const plain = block("text", "just words");
    const html = await highlightMarkdownCodeBlocks(
      [block("sql", "select 1"), plain, block("sql", "select 1"), block("sql", "delete from t")].join("\n"),
    );

    const blocks = html.split("\n");
    expect(blocks).toHaveLength(4);
    expect(blocks[0]).toBe(blocks[2]);
    expect(blocks[0]).toContain('<span class="token-keyword">select</span>');
    expect(blocks[1]).toBe(plain);
    expect(blocks[3]).toContain('<span class="token-keyword">delete</span>');
  });
});
