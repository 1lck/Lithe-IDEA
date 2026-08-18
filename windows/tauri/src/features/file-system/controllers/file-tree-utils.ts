import type { FileEntry } from "../types/app.types";
import { getDirName } from "@/utils/path-helpers";

export function sortFileEntries(entries: FileEntry[]): FileEntry[] {
  return entries.sort((a, b) => {
    // Directories come first
    if (a.isDir && !b.isDir) return -1;
    if (!a.isDir && b.isDir) return 1;

    // Then sort alphabetically (case-insensitive)
    return a.name.toLowerCase().localeCompare(b.name.toLowerCase());
  });
}

export function findFileInTree(files: FileEntry[], targetPath: string): FileEntry | null {
  for (const file of files) {
    if (file.path === targetPath) {
      return file;
    }
    if (file.children) {
      const found = findFileInTree(file.children, targetPath);
      if (found) return found;
    }
  }
  return null;
}

export function updateFileInTree(
  files: FileEntry[],
  targetPath: string,
  updater: (file: FileEntry) => FileEntry,
): FileEntry[] {
  let changed = false;
  const updatedFiles = files.map((file) => {
    if (file.path === targetPath) {
      const updatedFile = updater(file);
      if (updatedFile !== file) changed = true;
      return updatedFile;
    }
    if (file.children) {
      const updatedChildren = updateFileInTree(file.children, targetPath, updater);
      if (updatedChildren !== file.children) {
        changed = true;
        return {
          ...file,
          children: updatedChildren,
        };
      }
    }
    return file;
  });
  return changed ? updatedFiles : files;
}

export function getCompactFolderChild(item: FileEntry): FileEntry | null {
  if (!item.isDir || item.isEditing || item.isRenaming || item.isNewItem || !item.children) {
    return null;
  }

  if (item.children.length !== 1) {
    return null;
  }

  const child = item.children[0];
  return child.isDir && !child.isEditing && !child.isRenaming && !child.isNewItem ? child : null;
}

export async function loadFolderExpansion(
  files: FileEntry[],
  startPath: string,
  compactFolders: boolean,
  readChildren: (path: string) => Promise<FileEntry[]>,
) {
  const expandedPaths: string[] = [];
  const loadedChildren = new Map<string, FileEntry[]>();
  const visitedPaths = new Set<string>();
  let nextFiles = files;
  let currentPath = startPath;

  while (true) {
    if (visitedPaths.has(currentPath)) break;
    visitedPaths.add(currentPath);
    const folder = findFileInTree(nextFiles, currentPath);
    if (!folder?.isDir) break;

    let children = folder.children;
    if (!children || children.length === 0) {
      children = await readChildren(currentPath);
      loadedChildren.set(currentPath, children);
      nextFiles = updateFileInTree(nextFiles, currentPath, (item) => ({ ...item, children }));
    }

    expandedPaths.push(currentPath);
    const child = compactFolders ? getCompactFolderChild({ ...folder, children }) : null;
    if (!child) break;
    currentPath = child.path;
  }

  return {
    expandedPaths,
    finalPath: expandedPaths[expandedPaths.length - 1] ?? startPath,
    loadedChildren,
  };
}

export function removeFileFromTree(files: FileEntry[], targetPath: string): FileEntry[] {
  let changed = false;
  const nextFiles: FileEntry[] = [];

  for (const file of files) {
    if (file.path === targetPath) {
      changed = true;
      continue;
    }

    if (file.children) {
      const updatedChildren = removeFileFromTree(file.children, targetPath);
      if (updatedChildren !== file.children) {
        changed = true;
        nextFiles.push({
          ...file,
          children: updatedChildren,
        });
        continue;
      }
    }

    nextFiles.push(file);
  }

  return changed ? nextFiles : files;
}

function isDirectoryChildrenRoot(files: FileEntry[], parentPath: string): boolean {
  if (files.length === 0 || !files[0].path) return false;
  return parentPath === getDirName(files[0].path);
}

function appendSortedFile(files: FileEntry[], newFile: FileEntry): FileEntry[] {
  return sortFileEntries([...files, newFile]);
}

export function addFileToTree(
  files: FileEntry[],
  parentPath: string,
  newFile: FileEntry,
): FileEntry[] {
  // If parentPath is empty or root, add to top level
  if (!parentPath || parentPath === "/" || parentPath === "\\") {
    return appendSortedFile(files, newFile);
  }

  // Check if parentPath matches the root folder (when files are direct children of parentPath)
  // This happens when creating files in the root directory
  if (isDirectoryChildrenRoot(files, parentPath)) {
    return appendSortedFile(files, newFile);
  }

  let changed = false;
  const result = files.map((file) => {
    if (file.path === parentPath && file.isDir) {
      changed = true;
      const children = appendSortedFile(file.children || [], newFile);
      return { ...file, children };
    }
    if (file.children) {
      const updatedChildren = addFileToTree(file.children, parentPath, newFile);
      if (updatedChildren !== file.children) {
        changed = true;
        return {
          ...file,
          children: updatedChildren,
        };
      }
    }
    return file;
  });
  return changed ? result : files;
}
