import type { Ref } from "react";
import { convertFileSrc } from "@/platform/tauri-core";
import {
  getProjectAvatarBackground,
  getProjectAvatarInitials,
} from "@/features/window/utils/project-avatar";
import { cn } from "@/utils/cn";

interface ProjectAvatarProps {
  name: string;
  path: string;
  /** Rendered edge length in px; IntelliJ's toolbar avatar is 20px. */
  size?: number;
  customIconPath?: string;
  /** IntelliJ desaturates the avatar of a project that no longer exists. */
  missing?: boolean;
  className?: string;
  avatarRef?: Ref<HTMLElement>;
}

/**
 * IntelliJ generated project avatar (AvatarIcon, arcRatio 0.4): a rounded square with the
 * project's Avatar gradient and white JetBrains Mono semi-bold initials at 13/20 of its size.
 * Its color index matches the project-color window gradient.
 */
export function ProjectAvatar({
  name,
  path,
  size = 20,
  customIconPath,
  missing = false,
  className,
  avatarRef,
}: ProjectAvatarProps) {
  if (customIconPath) {
    return (
      <img
        ref={avatarRef as Ref<HTMLImageElement>}
        src={convertFileSrc(customIconPath)}
        alt=""
        className={cn("shrink-0 rounded-md object-contain", missing && "grayscale", className)}
        style={{ width: size, height: size }}
      />
    );
  }

  return (
    <span
      ref={avatarRef}
      aria-hidden="true"
      className={cn(
        "grid shrink-0 select-none place-items-center font-semibold text-white leading-none",
        missing && "grayscale",
        className,
      )}
      style={{
        width: size,
        height: size,
        // arcRatio 0.4 is the corner arc diameter, i.e. a radius of 0.2 * size.
        borderRadius: size * 0.2,
        background: getProjectAvatarBackground(path),
        fontFamily: '"JetBrains Mono", var(--font-mono)',
        fontSize: Math.floor((13 * size) / 20),
      }}
    >
      {getProjectAvatarInitials(name)}
    </span>
  );
}
