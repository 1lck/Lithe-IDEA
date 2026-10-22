import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseXml } from '../provider/xml.mjs';

test('reads elements, attributes in any quoting, text, and references', () => {
  const root = parseXml(`<?xml version="1.0" encoding="UTF-8"?>
<!-- svn writes no comments, but a reader must skip them -->
<log>
<logentry
   revision="7" kind='file' note="a &gt; b &amp; &#x4E2D;&#25991;">
<msg>Fix &lt;tag&gt; &quot;quoted&quot; &apos;single&apos;</msg>
<empty/>
<data><![CDATA[<kept> & raw]]></data>
</logentry>
</log>`);
  assert.equal(root.name, 'log');
  const entry = root.child('logentry');
  assert.deepEqual(entry.attributes, { revision: '7', kind: 'file', note: 'a > b & 中文' });
  assert.equal(entry.textOf('msg'), `Fix <tag> "quoted" 'single'`);
  assert.equal(entry.textOf('empty'), '');
  assert.equal(entry.textOf('data'), '<kept> & raw');
  assert.equal(entry.textOf('missing'), null);
  assert.equal(entry.child('missing'), null);
  assert.deepEqual(
    root.all('logentry').map((element) => element.name),
    ['logentry'],
  );
});

test('a > inside a quoted attribute value does not end the tag', () => {
  const root = parseXml('<target path="a>b.txt"><entry/></target>');
  assert.equal(root.attributes.path, 'a>b.txt');
  assert.equal(root.all('entry').length, 1);
});

test('keeps message whitespace and line breaks as written', () => {
  const root = parseXml('<msg>  first line\n\n  indented\n</msg>');
  assert.equal(root.text, '  first line\n\n  indented\n');
});

test('refuses documents it cannot read completely', () => {
  for (const [source, message] of [
    ['', /empty/],
    ['<?xml version="1.0"?>', /empty/],
    ['<status><target>', /not closed/],
    ['<status><target path="x', /not closed/],
    ['<status></target>', /Unexpected closing tag/],
    ['<a/><b/>', /more than one root/],
    ['text<a/>', /outside/],
    ['<a>&unknown;</a>', /Unknown XML entity/],
    ['<a><!-- open', /comment is not closed/],
  ]) {
    assert.throws(() => parseXml(source), message, source);
  }
});
