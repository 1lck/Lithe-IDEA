import { expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as dialog from "@/ui/dialog";
import * as select from "@/ui/settings-select";
import { useUpdateStore } from "../stores/update.store";
import { UpdateChannelSelector } from "./update-channel-selector";

test("selector shows the rolling warning and requires confirmation before saving AutoBuild", async () => {
  const restoreDom = installHappyDom();
  const previous = useUpdateStore.getState();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const container = document.createElement("div");
  const frame = spyOn(dialog, "default").mockImplementation(({ children, footer }) => (
    <div role="dialog">{children}{footer}</div>
  ));
  // Exercise the owning selector callbacks; the mature Select owns popup/focus behavior.
  const picker = spyOn(select, "default").mockImplementation(({ onChange, disabled, value }) => (
    <button disabled={disabled} onClick={() => onChange("autobuild")}>choose-{value}</button>
  ));
  const root = createRoot(container);
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    useUpdateStore.setState({ channel: "stable", status: "idle", operationBusy: false });
    await act(async () => root.render(<LocaleProvider language="en-US"><UpdateChannelSelector /></LocaleProvider>));
    expect(container.textContent).toContain("many bugs and unfinished features");
    expect(container.textContent).toContain("Ordinary users should stay on Stable");
    await act(async () => container.querySelector("button")?.click());
    expect(container.querySelector('[role="dialog"]')).not.toBeNull();
    expect(useUpdateStore.getState().channel).toBe("stable");
    const cancel = Array.from(container.querySelectorAll("button")).find((button) => button.textContent === "Cancel");
    expect(cancel).toBeDefined();
    await act(async () => cancel?.click());
    expect(useUpdateStore.getState().channel).toBe("stable");
    expect(container.querySelector('[role="dialog"]')).toBeNull();
    await act(async () => container.querySelector("button")?.click());
    const confirm = Array.from(container.querySelectorAll("button")).find((button) => button.textContent?.includes("use AutoBuild"));
    expect(confirm).toBeDefined();
    await act(async () => confirm?.click());
    expect(useUpdateStore.getState().channel).toBe("autobuild");
    expect(container.querySelector('[role="dialog"]')).toBeNull();
    expect(container.textContent).toContain("many bugs and unfinished features");
    await act(async () => useUpdateStore.setState({ operationBusy: true }));
    expect(container.querySelector("button")?.disabled).toBe(true);
  } finally {
    try {
      await act(async () => root.unmount());
    } finally {
      useUpdateStore.setState(previous, true);
      picker.mockRestore();
      frame.mockRestore();
      container.remove();
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      restoreDom();
    }
  }
});
