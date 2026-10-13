import { expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import NumberInput from "./number-input";

test("step buttons change the controlled value, respect bounds and disable editing", async () => {
  const restoreDom = installHappyDom();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const host = document.createElement("div");
  let root: Root | undefined;
  function Probe({
    disabled = false,
    readOnly = false,
  }: {
    disabled?: boolean;
    readOnly?: boolean;
  }) {
    const [value, setValue] = useState(9);
    return (
      <LocaleProvider language="en-US">
        <NumberInput
          value={value}
          onChange={setValue}
          min={8}
          max={10}
          size="md"
          disabled={disabled}
          readOnly={readOnly}
        />
      </LocaleProvider>
    );
  }
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    document.body.append(host);
    root = createRoot(host);
    const mountedRoot = root;
    await act(async () => mountedRoot.render(<Probe />));
    const input = host.querySelector<HTMLInputElement>("input[data-setting-primary-control]")!;
    const decrease = host.querySelector<HTMLButtonElement>('button[aria-label="Decrease value"]')!;
    const increase = host.querySelector<HTMLButtonElement>('button[aria-label="Increase value"]')!;
    expect(
      Array.from(host.querySelectorAll("button"), (button) => button.getAttribute("aria-label")),
    ).toEqual(["Increase value", "Decrease value"]);
    expect(input.value).toBe("9");
    await act(async () => increase.click());
    expect(input.value).toBe("10");
    expect(increase.disabled).toBe(true);
    await act(async () => decrease.click());
    await act(async () => decrease.click());
    expect(input.value).toBe("8");
    expect(decrease.disabled).toBe(true);
    await act(async () => mountedRoot.render(<Probe disabled />));
    expect(input.disabled).toBe(true);
    expect(increase.disabled).toBe(true);
    await act(async () => mountedRoot.render(<Probe readOnly />));
    expect(input.readOnly).toBe(true);
    await act(async () => increase.click());
    expect(input.value).toBe("8");
  } finally {
    try {
      await act(async () => root?.unmount());
    } finally {
      host.remove();
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      restoreDom();
    }
  }
});
