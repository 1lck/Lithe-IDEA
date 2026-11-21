import { pathToFileURL } from "node:url";

// Keep the required lanes explicit: an omitted dependency must never pass the gate.
export function verifyCIGate(needs, draft) {
  const lanes = ["pins", "linux", "linux-test", "remote-server", "macos", "windows"];
  const failures = lanes.filter((lane) => {
    const result = needs?.[lane]?.result;
    return result !== "success" && !(draft && ["macos", "windows"].includes(lane) && result === "skipped");
  });
  if (failures.length) {
    throw new Error(`Required CI lanes did not pass: ${failures.map((lane) => `${lane}=${needs?.[lane]?.result ?? "missing"}`).join(", ")}`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (!["true", "false"].includes(process.env.CI_DRAFT)) throw new Error("CI_DRAFT must be true or false");
  verifyCIGate(JSON.parse(process.env.CI_NEEDS), process.env.CI_DRAFT === "true");
  console.log("Required Desktop CI lanes passed.");
}
