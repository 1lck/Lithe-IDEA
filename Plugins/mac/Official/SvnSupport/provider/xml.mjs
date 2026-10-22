// A small XML reader for the documents `svn --xml` writes: elements,
// attributes, text, character references, and the XML declaration. The
// plugin package runs offline without node_modules, so it carries its own
// reader instead of a dependency. It does not validate against a DTD and
// rejects documents it cannot read completely, such as the partial output
// svn leaves when a command fails midway.

const NAMED_ENTITIES = { lt: '<', gt: '>', amp: '&', quot: '"', apos: "'" };

/** One element: its name, attributes, child elements, and direct text. */
export class XmlElement {
  constructor(name, attributes) {
    this.name = name;
    this.attributes = attributes;
    this.children = [];
    this.text = '';
  }

  /** The first child element named `name`, or `null`. */
  child(name) {
    return this.children.find((element) => element.name === name) ?? null;
  }

  /** Every child element named `name`, in document order. */
  all(name) {
    return this.children.filter((element) => element.name === name);
  }

  /** Text of the first child element named `name`, or `null` without one. */
  textOf(name) {
    return this.child(name)?.text ?? null;
  }
}

function decode(text) {
  return text.replace(/&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/g, (reference, body) => {
    if (body.startsWith('#x')) return String.fromCodePoint(Number.parseInt(body.slice(2), 16));
    if (body.startsWith('#')) return String.fromCodePoint(Number.parseInt(body.slice(1), 10));
    if (body in NAMED_ENTITIES) return NAMED_ENTITIES[body];
    throw new Error(`Unknown XML entity ${reference}.`);
  });
}

/** Index of the `>` that ends the tag starting at `start`, skipping quoted values. */
function tagEnd(source, start) {
  let quote = null;
  for (let index = start; index < source.length; index += 1) {
    const character = source[index];
    if (quote) {
      if (character === quote) quote = null;
    } else if (character === '"' || character === "'") {
      quote = character;
    } else if (character === '>') {
      return index;
    }
  }
  throw new Error('An XML tag is not closed.');
}

function parseTag(body) {
  const match = /^([^\s/>]+)/.exec(body);
  if (!match) throw new Error('An XML tag has no name.');
  const attributes = {};
  const rest = body.slice(match[1].length);
  for (const attribute of rest.matchAll(/([^\s=]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) {
    attributes[attribute[1]] = decode(attribute[2] ?? attribute[3]);
  }
  return new XmlElement(match[1], attributes);
}

/**
 * Parses a complete document and returns its root element.
 *
 * @param {string} source
 * @returns {XmlElement}
 */
export function parseXml(source) {
  const stack = [];
  let root = null;
  let index = 0;
  const appendText = (text) => {
    if (stack.length > 0) stack.at(-1).text += decode(text);
    else if (text.trim() !== '') throw new Error('Text outside the XML root element.');
  };
  while (index < source.length) {
    const open = source.indexOf('<', index);
    if (open === -1) {
      appendText(source.slice(index));
      break;
    }
    if (open > index) appendText(source.slice(index, open));
    if (source.startsWith('<?', open)) {
      const end = source.indexOf('?>', open);
      if (end === -1) throw new Error('An XML declaration is not closed.');
      index = end + 2;
    } else if (source.startsWith('<!--', open)) {
      const end = source.indexOf('-->', open);
      if (end === -1) throw new Error('An XML comment is not closed.');
      index = end + 3;
    } else if (source.startsWith('<![CDATA[', open)) {
      const end = source.indexOf(']]>', open);
      if (end === -1 || stack.length === 0) throw new Error('A CDATA section is not closed.');
      stack.at(-1).text += source.slice(open + 9, end);
      index = end + 3;
    } else if (source[open + 1] === '/') {
      const end = tagEnd(source, open);
      const name = source.slice(open + 2, end).trim();
      const element = stack.pop();
      if (element?.name !== name) throw new Error(`Unexpected closing tag </${name}>.`);
      index = end + 1;
    } else {
      const end = tagEnd(source, open);
      const selfClosing = source[end - 1] === '/';
      const element = parseTag(source.slice(open + 1, selfClosing ? end - 1 : end));
      if (stack.length > 0) stack.at(-1).children.push(element);
      else if (root === null) root = element;
      else throw new Error('An XML document has more than one root element.');
      if (!selfClosing) stack.push(element);
      index = end + 1;
    }
  }
  if (root === null) throw new Error('The XML document is empty.');
  if (stack.length > 0) throw new Error(`The XML element <${stack.at(-1).name}> is not closed.`);
  return root;
}
