import { expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import * as api from "../lib/file-search-api";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useFffSearch } from "./use-fff-search";

test("an old root set cannot publish after nested-root ownership changes", async () => {
  const restoreDom = installHappyDom();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  let finish!: (hits: api.FffSearchHit[]) => void;
  const old = new Promise<api.FffSearchHit[]>((resolve) => {
    finish = resolve;
  });
  const search = spyOn(api, "fffSearchFiles")
    .mockImplementationOnce(() => old)
    .mockResolvedValue([]);
  const host = document.createElement("div");
  const root = createRoot(host);
  let result: ReturnType<typeof useFffSearch> | undefined;
  function Probe({ roots }: { roots: string[] }) {
    result = useFffSearch("needle", true, roots);
    return null;
  }
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    document.body.append(host);
    await act(async () => root.render(<Probe roots={["C:/main"]} />));
    await act(async () => root.render(<Probe roots={["C:/main", "C:/main/nested"]} />));
    await act(async () =>
      finish([
        {
          path: "C:/main/nested/Excluded.java",
          name: "Excluded.java",
          relative_path: "nested/Excluded.java",
          score: 1,
        },
      ]),
    );
    expect(result?.hits).toEqual([]);
    expect(result?.isSearching).toBe(false);
    expect(search).toHaveBeenCalledTimes(2);
  } finally {
    finish([]);
    try {
      await act(async () => root.unmount());
    } finally {
      search.mockRestore();
      host.remove();
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      restoreDom();
    }
  }
});
