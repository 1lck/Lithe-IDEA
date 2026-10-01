import { describe, expect, test } from "bun:test";
import type { AgentSessionConfigOption } from "../types/agent.types";
import {
  choiceTitle,
  contextUsageDetails,
  filteredChoices,
  modelSummary,
  optionTitle,
  partitionOptions,
  quotaWindowLabel,
} from "./agent-session-selectors";

const zh = {
  language: "zh-CN" as const,
  thinkingLevel: "思考强度",
  speed: "速度",
  standard: "标准",
  fast: "快速",
};

function option(
  id: string,
  category: string | null,
  currentValue: string,
  choices: [string, string, string?][],
  name = id,
): AgentSessionConfigOption {
  return {
    id,
    name,
    category,
    currentValue,
    choices: choices.map(([choiceID, choiceName, group]) => ({
      id: choiceID,
      name: choiceName,
      group: group ?? null,
      description: null,
    })),
  };
}

const model = option("model", "model", "gpt-5.5", [
  ["gpt-5.5", "gpt-5.5", "OpenAI"],
  ["gpt-5.5-mini", "gpt-5.5-mini", "OpenAI"],
]);
const effort = option("effort", "thought_level", "high", [
  ["high", "High"],
  ["low", "Low"],
]);
const mode = option("mode", "mode", "agent", [["agent", "Ask for approval"]], "Approval mode");
const fast = option("fast-mode", null, "off", [
  ["off", "Off"],
  ["on", "On"],
]);

describe("Agent session selectors", () => {
  test("options are split into model, mode and ordered settings", () => {
    const parts = partitionOptions([fast, mode, effort, model]);
    expect(parts.model?.id).toBe("model");
    expect(parts.mode?.id).toBe("mode");
    expect(parts.settings.map((entry) => entry.id)).toEqual(["effort", "fast-mode"]);
  });

  test("labels follow macOS: localized Agent names, fixed speed and effort titles", () => {
    expect(optionTitle(mode, zh)).toBe("权限模式");
    expect(optionTitle(effort, zh)).toBe("思考强度");
    expect(optionTitle(fast, zh)).toBe("速度");
    expect(choiceTitle(fast.choices[1], fast, zh)).toBe("快速");
    // Model names are product identifiers and are never translated.
    expect(choiceTitle(model.choices[0], model, zh)).toBe("gpt-5.5");
    expect(modelSummary(model, [model, effort], zh)).toBe("gpt-5.5 高");
  });

  test("model search matches name, id and group", () => {
    expect(filteredChoices(model, "MINI").map((choice) => choice.id)).toEqual(["gpt-5.5-mini"]);
    expect(filteredChoices(model, "openai")).toHaveLength(2);
    expect(filteredChoices(model, "  ")).toHaveLength(2);
  });

  test("context details keep the zero placeholder until the Agent reports usage", () => {
    const format = {
      percent: (fraction: number, digits: number) => `${(fraction * 100).toFixed(digits)}%`,
      placeholder: (percent: string) => `上下文: ${percent}`,
      tokens: (percent: string, used: string, capacity: string) =>
        `${percent} · ${used} / ${capacity} 上下文 token`,
    };
    expect(contextUsageDetails(null, format)).toBe("上下文: 0.0%");
    expect(
      contextUsageDetails({ usedTokens: 45_600, capacityTokens: 200_000, fraction: 0.228 }, format),
    ).toBe("22.8% · 45.6k / 200k 上下文 token");
  });

  test("quota windows use exact day, hour or minute multiples", () => {
    expect(quotaWindowLabel(18_000)).toBe("5h");
    expect(quotaWindowLabel(604_800)).toBe("7d");
    expect(quotaWindowLabel(5_400)).toBe("90m");
  });
});
