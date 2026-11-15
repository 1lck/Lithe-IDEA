import React, { useState } from "react";

type Props = { title: string; items: string[] };

export function List({ title, items }: Props): JSX.Element {
  const [open, setOpen] = useState<boolean>(false);
  return (
    <section className="list" data-open={open}>
      <h2 onClick={() => setOpen(!open)}>{title}</h2>
      {open && (
        <ul>
          {items.map((item, i) => (
            <li key={i}>{item.toUpperCase()}</li>
          ))}
        </ul>
      )}
      <Footer<string> value="done" />
    </section>
  );
}

function Footer<T>({ value }: { value: T }) {
  return <footer>{String(value)}</footer>;
}
