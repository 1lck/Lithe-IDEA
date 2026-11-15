import { createRoot } from "react-dom/client";

function App({ name }) {
  const style = { color: "red", fontSize: 12 };
  return (
    <div style={style} className="app">
      Hello, <b>{name}</b>!
      <input type="text" disabled />
      {/* a comment */}
    </div>
  );
}

createRoot(document.getElementById("root")).render(<App name="world" />);
