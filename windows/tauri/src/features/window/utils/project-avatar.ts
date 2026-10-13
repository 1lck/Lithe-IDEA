import { getProjectGradientColorIndex } from "./project-gradient";

/**
 * IntelliJ Islands RecentProject.ColorN.Avatar.Start / End, indexed like the project gradient
 * colors so a project's avatar and window gradient always match. Islands Light inherits the
 * same avatar colors, so they do not depend on the theme.
 */
const PROJECT_AVATAR_GRADIENTS: ReadonlyArray<readonly [start: string, end: string]> = [
  ["#e08855", "#e9806f"],
  ["#b08b14", "#bb7f19"],
  ["#a1a359", "#87aa59"],
  ["#3b92b8", "#6183ec"],
  ["#3574f0", "#7a64f0"],
  ["#c84d8f", "#a956cf"],
  ["#955ae0", "#a84de0"],
  ["#24a394", "#279ccd"],
  ["#5fad65", "#3d968b"],
];

/**
 * CSS background of a generated project avatar. IntelliJ AvatarUtils paints Avatar.End at the
 * bottom-left corner and Avatar.Start at the top-right one.
 */
export function getProjectAvatarBackground(projectPath: string): string {
  const [start, end] = PROJECT_AVATAR_GRADIENTS[getProjectGradientColorIndex(projectPath) - 1];
  return `linear-gradient(to top right, ${end}, ${start})`;
}

const LETTER_OR_DIGIT = /[\p{L}\p{N}]/u;

/**
 * Two-letter avatar text, ported from IntelliJ AvatarUtils.initials: camel-case capitals first
 * ("MyProject" -> "MP"), otherwise the first and last words split on the first separator that
 * yields two words ("Lithe-IDEA-issue-35-ci" -> "LC"), otherwise the single camel-case letter.
 */
export function getProjectAvatarInitials(name: string): string {
  const camelCase = camelCaseInitials(name);
  if (camelCase.length === 2) return camelCase;

  const text = name.trim();
  for (const delimiters of [" ", ",", "-", "_", ".", "`'\""]) {
    const words = text
      .split(new RegExp(`[${delimiters.replace(/[-\\\]^]/g, "\\$&")}]`))
      .map((word) => Array.from(word).filter((character) => LETTER_OR_DIGIT.test(character)))
      .filter((characters) => characters.length > 0);
    if (words.length >= 2) {
      return `${words[0][0]}${words[words.length - 1][0]}`.toUpperCase();
    }
  }

  return camelCase;
}

function camelCaseInitials(text: string): string {
  const characters = Array.from(text);
  const start = characters.findIndex((character) => /\p{L}/u.test(character));
  if (start < 0) return "";

  const initials: string[] = [];
  for (let index = start; index < characters.length; index++) {
    const character = characters[index];
    if (!LETTER_OR_DIGIT.test(character)) break;
    if (index === start || /\p{Lu}/u.test(character)) initials.push(character);
    if (initials.length === 2) break;
  }
  return initials.join("").toUpperCase();
}
