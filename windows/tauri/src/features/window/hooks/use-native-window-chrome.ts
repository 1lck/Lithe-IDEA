import { invoke } from "@/platform/tauri-core";
import { useEffect, useState } from "react";
import { IS_LINUX } from "@/utils/platform";

export function useNativeWindowChrome() {
  // Lithe draws its own title bar on Linux, so start from custom chrome and let
  // the backend confirm whether the platform adds a native frame.
  const [usesNativeWindowChrome, setUsesNativeWindowChrome] = useState(false);

  useEffect(() => {
    if (!IS_LINUX) {
      setUsesNativeWindowChrome(false);
      return;
    }

    let cancelled = false;

    void invoke<boolean>("uses_native_window_chrome")
      .then((value) => {
        if (!cancelled) {
          setUsesNativeWindowChrome(value);
        }
      })
      .catch((error) => {
        console.error("Failed to detect native window chrome:", error);
        if (!cancelled) {
          setUsesNativeWindowChrome(false);
        }
      });

    return () => {
      cancelled = true;
    };
  }, []);

  return usesNativeWindowChrome;
}
