import { Menu as DropdownMenuPrimitive } from "@base-ui/react/menu";
import { cva } from "class-variance-authority";
import {
  type ComponentProps,
  type CSSProperties,
  type MouseEvent as ReactMouseEvent,
  type ReactNode,
  type RefObject,
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from "react";
import { buttonVariants } from "@/ui/button";
import Input from "@/ui/input";
import { quickTransition } from "@/utils/motion";
import { FloatingPopoverContent } from "@/ui/popover";
import { useTranslation } from "@/i18n/locale-provider";
import { cn } from "@/utils/cn";
import { matchesSearchQuery } from "@/utils/search-match";
import { bindScrollContainerWheel } from "@/ui/scroll-container-wheel";
import { CaretRightIcon, CheckIcon, MagnifyingGlassIcon as Search } from "@/ui/icons";

export const DROPDOWN_TRIGGER_BASE = cn(
  buttonVariants({
    variant: "default",
    size: "xs",
  }),
  "min-w-0 gap-1 rounded-md px-2 text-subtle-foreground",
);

export type DropdownDensity = "default" | "compact";

const dropdownItemVariants = cva(
  "font-sans ui-text-sm flex w-full items-center justify-between whitespace-nowrap text-left text-foreground transition-colors",
  {
    variants: {
      density: {
        default: "gap-3 rounded-lg px-2.5 py-1.5",
        compact: "gap-2 rounded-md px-2 py-1",
      },
      disabled: {
        true: "cursor-not-allowed opacity-50",
        false: "cursor-pointer hover:bg-accent",
      },
      focused: {
        true: "bg-accent",
        false: "",
      },
    },
    defaultVariants: {
      density: "default",
      disabled: false,
      focused: false,
    },
  },
);

const dropdownSectionLabelVariants = cva("font-sans ui-text-sm text-subtle-foreground", {
  variants: {
    density: {
      default: "px-2.5 py-1",
      compact: "px-2 py-0.5",
    },
  },
  defaultVariants: {
    density: "default",
  },
});

export const DROPDOWN_ITEM_BASE = dropdownItemVariants();

export function dropdownTriggerClassName(className?: string) {
  return cn(DROPDOWN_TRIGGER_BASE, className);
}

export function dropdownItemClassName(className?: string) {
  return cn(DROPDOWN_ITEM_BASE, className);
}

export interface MenuItem {
  id: string;
  label: string;
  icon?: ReactNode;
  onClick: () => void;
  disabled?: boolean;
  separator?: boolean;
  keybinding?: ReactNode;
  className?: string;
  /** Nested items turn the entry into a submenu opened on hover or click. */
  children?: MenuItem[];
}

interface DropdownMenuState<T> {
  isOpen: boolean;
  position: { x: number; y: number };
  data: T | null;
}

export function useDropdownMenu<T = unknown>() {
  const [state, setState] = useState<DropdownMenuState<T>>({
    isOpen: false,
    position: { x: 0, y: 0 },
    data: null,
  });

  const open = useCallback((event: ReactMouseEvent, data?: T) => {
    event.preventDefault();
    event.stopPropagation();
    setState({
      isOpen: true,
      position: { x: event.clientX, y: event.clientY },
      data: data ?? null,
    });
  }, []);

  const openAt = useCallback((position: { x: number; y: number }, data?: T) => {
    setState({ isOpen: true, position, data: data ?? null });
  }, []);

  const close = useCallback(() => {
    setState({ isOpen: false, position: { x: 0, y: 0 }, data: null });
  }, []);

  return { ...state, open, openAt, close };
}

interface MenuItemsListProps {
  items: MenuItem[];
  onItemSelect?: () => void;
  className?: string;
  itemClassName?: string;
  focusIndex?: number;
  density?: DropdownDensity;
  showIcons?: boolean;
  /** Keyboard-opened submenu row (list index) with its highlighted enabled child index. */
  activeSubmenu?: { listIndex: number; childFocusIndex: number } | null;
}

const MENU_SUBMENU_ESTIMATED_WIDTH = 240;
const MENU_SUBMENU_ESTIMATED_ITEM_HEIGHT = 30;
const MENU_SUBMENU_VIEWPORT_PADDING = 8;

interface MenuSubmenuItemProps {
  item: MenuItem;
  itemClassName?: string;
  density: DropdownDensity;
  showIcons: boolean;
  focused: boolean;
  /** Shared-dropdown keyboard navigation opens the submenu without a pointer event. */
  keyboardOpen?: boolean;
  /** Enabled-child index highlighted by keyboard navigation inside the submenu. */
  keyboardChildFocusIndex?: number;
  onItemSelect?: () => void;
  registerRef?: (element: HTMLButtonElement | null) => void;
}

function MenuSubmenuItem({
  item,
  itemClassName,
  density,
  showIcons,
  focused,
  keyboardOpen,
  keyboardChildFocusIndex,
  onItemSelect,
  registerRef,
}: MenuSubmenuItemProps) {
  const [isOpen, setIsOpen] = useState(false);
  const [position, setPosition] = useState({ left: 0, top: 0 });
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const contentRef = useRef<HTMLDivElement | null>(null);

  const openSubmenu = useCallback(() => {
    const rect = triggerRef.current?.getBoundingClientRect();
    if (!rect) return;

    const viewportWidth = window.visualViewport?.width ?? window.innerWidth;
    const left =
      rect.right + MENU_SUBMENU_ESTIMATED_WIDTH > viewportWidth - 8
        ? Math.max(8, rect.left - MENU_SUBMENU_ESTIMATED_WIDTH)
        : rect.right;
    // Like JMenu, align the submenu with its parent row but slide it up when it would run
    // past the bottom of the window.
    const viewportHeight = window.visualViewport?.height ?? window.innerHeight;
    const estimatedHeight =
      (item.children?.length ?? 0) * MENU_SUBMENU_ESTIMATED_ITEM_HEIGHT +
      MENU_SUBMENU_VIEWPORT_PADDING;
    const top = Math.max(
      MENU_SUBMENU_VIEWPORT_PADDING,
      Math.min(rect.top, viewportHeight - MENU_SUBMENU_VIEWPORT_PADDING - estimatedHeight),
    );
    setPosition({ left, top });
    setIsOpen(true);
  }, [item.children]);

  const closeSubmenu = useCallback(() => setIsOpen(false), []);

  // Keyboard-driven open mirrors pointer interaction; the ref guard keeps hover-opened
  // submenus alive when callers rebuild their item arrays between renders.
  const keyboardOwned = useRef(false);
  useEffect(() => {
    if (keyboardOpen && !keyboardOwned.current) {
      keyboardOwned.current = true;
      openSubmenu();
    } else if (!keyboardOpen && keyboardOwned.current) {
      keyboardOwned.current = false;
      closeSubmenu();
    }
  }, [keyboardOpen, openSubmenu, closeSubmenu]);

  return (
    <>
      <button
        ref={(element) => {
          triggerRef.current = element;
          registerRef?.(element);
        }}
        type="button"
        role="menuitem"
        aria-haspopup="menu"
        aria-expanded={isOpen || keyboardOpen}
        disabled={item.disabled}
        onMouseEnter={() => {
          if (!item.disabled) openSubmenu();
        }}
        onFocus={() => {
          if (!item.disabled) openSubmenu();
        }}
        onClick={(event) => {
          event.stopPropagation();
          if (!item.disabled) openSubmenu();
        }}
        className={cn(
          dropdownItemVariants({
            density,
            disabled: item.disabled,
            focused,
          }),
          itemClassName,
          item.className,
        )}
      >
        {showIcons && item.icon && (
          <span
            className={cn(
              "grid shrink-0 place-items-center [&>svg]:block",
              density === "compact" ? "size-4 [&>svg]:size-4" : "size-4.5 [&>svg]:size-4.5",
            )}
          >
            {item.icon}
          </span>
        )}
        <span className="min-w-0 flex-1 truncate whitespace-nowrap">{item.label}</span>
        <CaretRightIcon
          className={cn(
            "shrink-0 text-subtle-foreground",
            density === "compact" ? "size-3.5" : "size-4",
          )}
        />
      </button>
      <FloatingPopoverContent
        isOpen={isOpen && !item.disabled}
        contentRef={contentRef}
        className="min-w-44"
        style={{ left: position.left, top: position.top }}
      >
        <div role="menu">
          <MenuItemsList
            items={item.children ?? []}
            focusIndex={
              translateKeyboardFocus(item.children ?? [], keyboardChildFocusIndex ?? -1)
                .localFocusIndex
            }
            density={density}
            showIcons={showIcons}
            onItemSelect={() => {
              closeSubmenu();
              onItemSelect?.();
            }}
          />
        </div>
      </FloatingPopoverContent>
    </>
  );
}

export function MenuItemsList({
  items,
  onItemSelect,
  className,
  itemClassName,
  focusIndex = -1,
  density = "default",
  showIcons = true,
  activeSubmenu,
}: MenuItemsListProps) {
  const itemRefs = useRef<(HTMLButtonElement | null)[]>([]);

  useEffect(() => {
    if (focusIndex >= 0 && itemRefs.current[focusIndex]) {
      itemRefs.current[focusIndex]?.scrollIntoView({ block: "nearest" });
    }
  }, [focusIndex]);

  let selectableIdx = -1;

  return (
    <div className={className}>
      {items.map((item) => {
        if (item.separator) {
          return <div key={item.id} className="my-0.5 border-border/70 border-t" />;
        }

        selectableIdx++;
        const index = selectableIdx;
        const isFocused = index === focusIndex;

        if (item.children && item.children.length > 0) {
          return (
            <MenuSubmenuItem
              key={item.id}
              item={item}
              itemClassName={itemClassName}
              density={density}
              showIcons={showIcons}
              focused={isFocused}
              keyboardOpen={activeSubmenu?.listIndex === index}
              keyboardChildFocusIndex={
                activeSubmenu?.listIndex === index ? activeSubmenu.childFocusIndex : undefined
              }
              onItemSelect={onItemSelect}
              registerRef={(element) => {
                if (!item.disabled) {
                  itemRefs.current[index] = element;
                }
              }}
            />
          );
        }

        return (
          <button
            key={item.id}
            ref={(el) => {
              if (!item.disabled) {
                itemRefs.current[index] = el;
              }
            }}
            type="button"
            role="menuitem"
            onClick={() => {
              if (item.disabled) return;
              item.onClick();
              onItemSelect?.();
            }}
            disabled={item.disabled}
            className={cn(
              dropdownItemVariants({
                density,
                disabled: item.disabled,
                focused: isFocused,
              }),
              itemClassName,
              item.className,
            )}
          >
            {showIcons && item.icon && (
              <span
                className={cn(
                  "grid shrink-0 place-items-center [&>svg]:block",
                  density === "compact" ? "size-4 [&>svg]:size-4" : "size-4.5 [&>svg]:size-4.5",
                )}
              >
                {item.icon}
              </span>
            )}
            <span className="min-w-0 flex-1 truncate whitespace-nowrap">{item.label}</span>
            {item.keybinding && (
              <span
                className={cn(
                  "ui-text-sm shrink-0 whitespace-nowrap text-subtle-foreground",
                  density === "compact" ? "ml-5" : "ml-8",
                )}
              >
                {item.keybinding}
              </span>
            )}
          </button>
        );
      })}
    </div>
  );
}

export interface DropdownSection {
  id: string;
  label?: string;
  items: MenuItem[];
}

// MenuItemsList numbers every non-separator row, disabled rows included, while the menu's
// keyboard index counts only enabled rows; translate between the two conventions so the
// highlighted row always matches the row Enter activates, in flat and grouped menus alike.
function translateKeyboardFocus(items: MenuItem[], keyboardIndex: number) {
  let remaining = keyboardIndex;
  let listIndex = -1;
  let enabledCount = 0;
  let localFocusIndex = -1;
  for (const item of items) {
    if (item.separator) continue;
    listIndex += 1;
    if (item.disabled) continue;
    if (remaining === 0 && localFocusIndex < 0) localFocusIndex = listIndex;
    remaining -= 1;
    enabledCount += 1;
  }
  return { localFocusIndex, enabledCount };
}

type AnchorSide = "top" | "bottom";
type AnchorAlign = "start" | "end";

interface DropdownBaseProps {
  isOpen: boolean;
  onClose: () => void;
  className?: string;
  menuClassName?: string;
  style?: CSSProperties;
  portalContainer?: Element | DocumentFragment | null;
  closeOnSelect?: boolean;
  animated?: boolean;
  matchAnchorWidth?: boolean;
  anchorMinWidth?: number;
  density?: DropdownDensity;
  showIcons?: boolean;
}

interface AnchorPositioning {
  anchorRef: RefObject<HTMLElement | null>;
  anchorSide?: AnchorSide;
  anchorAlign?: AnchorAlign;
  point?: never;
}

interface PointPositioning {
  point: { x: number; y: number };
  anchorRef?: never;
  anchorSide?: never;
  anchorAlign?: never;
}

type PositioningProps = AnchorPositioning | PointPositioning;

interface ItemsContent {
  items: MenuItem[];
  sections?: never;
  children?: never;
  searchable?: boolean;
  searchPlaceholder?: string;
}

interface SectionsContent {
  sections: DropdownSection[];
  items?: never;
  children?: never;
  searchable?: boolean;
  searchPlaceholder?: string;
}

interface ChildrenContent {
  children: ReactNode;
  items?: never;
  sections?: never;
  searchable?: never;
  searchPlaceholder?: never;
}

type ContentProps = ItemsContent | SectionsContent | ChildrenContent;

export type DropdownProps = DropdownBaseProps & PositioningProps & ContentProps;

const VIEWPORT_PADDING = 8;
const RESIZE_REPOSITION_THRESHOLD = 2;

function getNumericMaxHeight(value: CSSProperties["maxHeight"]) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string") {
    const match = value.trim().match(/^(\d+(?:\.\d+)?)px$/);
    if (match) {
      return Number.parseFloat(match[1]);
    }
  }
  return null;
}

function getViewportBounds() {
  const vv = window.visualViewport;
  if (!vv || !Number.isFinite(vv.width) || !Number.isFinite(vv.height)) {
    return { left: 0, top: 0, width: window.innerWidth, height: window.innerHeight };
  }
  return {
    left: Number.isFinite(vv.offsetLeft) ? vv.offsetLeft : 0,
    top: Number.isFinite(vv.offsetTop) ? vv.offsetTop : 0,
    width: vv.width,
    height: vv.height,
  };
}

function getMenuLayoutSize(menu: HTMLElement) {
  // Entrance transforms change getBoundingClientRect(), but must not change
  // collision detection or the locked width when a menu item receives focus.
  return { width: menu.offsetWidth, height: menu.offsetHeight };
}

// Keyboard indices count enabled non-separator rows; reusable for submenu children too.
function enabledMenuItems(items: MenuItem[]) {
  return items.filter((item) => !item.separator && !item.disabled);
}

export function Dropdown(props: DropdownProps) {
  const { t } = useTranslation();
  const {
    isOpen,
    onClose,
    className,
    menuClassName,
    style,
    searchable,
    searchPlaceholder,
    portalContainer,
    closeOnSelect = true,
    animated = true,
    matchAnchorWidth = false,
    anchorMinWidth = 0,
    density = "default",
    showIcons = true,
  } = props;

  const menuRef = useRef<HTMLDivElement>(null);
  const searchRef = useRef<HTMLInputElement>(null);
  const lockedWidthRef = useRef<number | null>(null);
  const lastMenuSizeRef = useRef<{ width: number; height: number } | null>(null);
  const [searchQuery, setSearchQuery] = useState("");
  const [focusIndex, setFocusIndex] = useState(-1);
  // Enabled-item index whose submenu is keyboard-open, plus the highlighted enabled child
  // inside it. null/-1 mean keyboard navigation stays on the parent rows.
  const [openSubmenuIndex, setOpenSubmenuIndex] = useState<number | null>(null);
  const [submenuFocusIndex, setSubmenuFocusIndex] = useState(-1);
  const [resolvedSide, setResolvedSide] = useState<AnchorSide>("bottom");
  const [isPositioned, setIsPositioned] = useState(false);

  const isAnchorMode = "anchorRef" in props && props.anchorRef != null;
  const anchorRef = isAnchorMode ? (props as AnchorPositioning).anchorRef : null;
  const anchorSide = isAnchorMode
    ? ((props as AnchorPositioning).anchorSide ?? "bottom")
    : "bottom";
  const anchorAlign = isAnchorMode
    ? ((props as AnchorPositioning).anchorAlign ?? "start")
    : "start";
  const point = !isAnchorMode ? (props as PointPositioning).point : null;

  const hasItems = "items" in props && props.items != null;
  const hasSections = "sections" in props && props.sections != null;
  const hasChildren = "children" in props && props.children != null;

  const getAllItems = useCallback((): MenuItem[] => {
    if (hasItems) return props.items!;
    if (hasSections) return props.sections!.flatMap((s) => s.items);
    return [];
  }, [hasItems, hasSections, props]);

  const getFilteredItems = useCallback((): MenuItem[] => {
    const all = getAllItems();
    if (!searchQuery.trim()) return all;
    return all.filter((item) => !item.separator && matchesSearchQuery(searchQuery, [item.label]));
  }, [getAllItems, searchQuery]);

  const getFilteredSections = useCallback((): DropdownSection[] => {
    if (!hasSections) return [];
    if (!searchQuery.trim()) return props.sections!;
    return props
      .sections!.map((section) => ({
        ...section,
        items: section.items.filter(
          (item) => !item.separator && matchesSearchQuery(searchQuery, [item.label]),
        ),
      }))
      .filter((section) => section.items.length > 0);
  }, [hasSections, searchQuery, props]);

  const positionMenu = useCallback(() => {
    const menu = menuRef.current;
    if (!menu) return;

    const vp = getViewportBounds();
    const userMaxHeight = getNumericMaxHeight(style?.maxHeight);
    const hasExplicitWidth = style?.width != null;

    const applyMaxHeight = (height: number) => {
      const nextHeight = userMaxHeight == null ? height : Math.min(height, userMaxHeight);
      menu.style.maxHeight = `${nextHeight}px`;
    };

    const applyAnchorWidth = (anchorRect: DOMRect) => {
      if (!matchAnchorWidth || hasExplicitWidth) return;

      const anchorWidth = Math.round(anchorRect.width);
      if (Number.isFinite(anchorWidth)) {
        menu.style.width = `${Math.max(anchorMinWidth, anchorWidth)}px`;
      }
    };

    const applyLockedWidth = () => {
      if (hasExplicitWidth || matchAnchorWidth) return;

      if (lockedWidthRef.current == null) {
        lockedWidthRef.current = getMenuLayoutSize(menu).width;
      }

      if (lockedWidthRef.current != null) {
        menu.style.width = `${lockedWidthRef.current}px`;
      }
    };

    let x: number;
    let y: number;
    let finalSide: AnchorSide = "bottom";

    if (anchorRef?.current) {
      const anchorRect = anchorRef.current.getBoundingClientRect();
      const viewportMaxHeight = Math.max(120, vp.height - VIEWPORT_PADDING * 2);
      const spaceBelow = vp.top + vp.height - anchorRect.bottom - VIEWPORT_PADDING;
      const spaceAbove = anchorRect.top - vp.top - VIEWPORT_PADDING;

      if (anchorSide === "bottom") {
        finalSide = spaceBelow >= spaceAbove ? "bottom" : "top";
      } else {
        finalSide = spaceAbove >= spaceBelow ? "top" : "bottom";
      }

      const availableHeight = finalSide === "bottom" ? spaceBelow : spaceAbove;
      applyMaxHeight(Math.max(120, Math.min(viewportMaxHeight, availableHeight)));
      applyAnchorWidth(anchorRect);
      applyLockedWidth();

      const menuSize = getMenuLayoutSize(menu);

      if (anchorAlign === "end") {
        x = anchorRect.right - menuSize.width;
      } else {
        x = anchorRect.left;
      }

      if (finalSide === "bottom") {
        if (menuSize.height <= spaceBelow || spaceBelow >= spaceAbove) {
          y = anchorRect.bottom + 6;
          finalSide = "bottom";
        } else {
          y = anchorRect.top - menuSize.height - 6;
          finalSide = "top";
        }
      } else {
        if (menuSize.height <= spaceAbove || spaceAbove >= spaceBelow) {
          y = anchorRect.top - menuSize.height - 6;
          finalSide = "top";
        } else {
          y = anchorRect.bottom + 6;
          finalSide = "bottom";
        }
      }
    } else if (point) {
      const maxH = Math.max(120, vp.height - VIEWPORT_PADDING * 2);
      applyMaxHeight(maxH);
      applyLockedWidth();

      // Same rule as IDEA's JPopupMenu.show(): the top-left corner is the click point, and a
      // menu that does not fit is slid back inside by the clamp below, never flipped around
      // the pointer.
      x = point.x;
      y = point.y;
    } else {
      return;
    }

    const menuSize = getMenuLayoutSize(menu);

    const minX = vp.left + VIEWPORT_PADDING;
    const maxX = vp.left + vp.width - menuSize.width - VIEWPORT_PADDING;
    const minY = vp.top + VIEWPORT_PADDING;
    const maxY = vp.top + vp.height - menuSize.height - VIEWPORT_PADDING;

    x = Math.max(minX, Math.min(x, maxX));
    y = Math.max(minY, Math.min(y, maxY));

    menu.style.left = `${Math.round(x)}px`;
    menu.style.top = `${Math.round(y)}px`;
    setResolvedSide(finalSide);
    setIsPositioned(true);
  }, [anchorRef, anchorSide, anchorAlign, point]);

  useLayoutEffect(() => {
    if (!isOpen) return;
    positionMenu();
  }, [isOpen, positionMenu, searchQuery]);

  useEffect(() => {
    if (isOpen) return;
    lockedWidthRef.current = null;
    lastMenuSizeRef.current = null;
    setIsPositioned(false);
    if (menuRef.current && style?.width == null) {
      menuRef.current.style.width = "";
    }
  }, [isOpen, style?.width]);

  useEffect(() => {
    if (!isOpen) return;

    const resizeObserver = new ResizeObserver((entries) => {
      const entry = entries[0];
      if (!entry) return;

      const { width, height } = entry.contentRect;
      const previousSize = lastMenuSizeRef.current;
      lastMenuSizeRef.current = { width, height };

      if (!previousSize) {
        positionMenu();
        return;
      }

      const widthDelta = Math.abs(width - previousSize.width);
      const heightDelta = Math.abs(height - previousSize.height);

      if (widthDelta < RESIZE_REPOSITION_THRESHOLD && heightDelta < RESIZE_REPOSITION_THRESHOLD) {
        return;
      }

      positionMenu();
    });
    if (menuRef.current) resizeObserver.observe(menuRef.current);

    const handleClickOutside = (e: MouseEvent) => {
      const target = e.target as Node;
      if (menuRef.current?.contains(target)) return;
      if (anchorRef?.current?.contains(target)) return;
      onClose();
    };

    const handleEscape = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        // Escape dismisses the keyboard-open submenu first, like IDEA's JMenu.
        if (openSubmenuIndex != null) setOpenSubmenuIndex(null);
        else onClose();
      }
    };

    window.addEventListener("resize", positionMenu);
    window.addEventListener("scroll", positionMenu, true);
    window.visualViewport?.addEventListener("resize", positionMenu);
    window.visualViewport?.addEventListener("scroll", positionMenu);
    document.addEventListener("mousedown", handleClickOutside);
    document.addEventListener("keydown", handleEscape, true);

    return () => {
      resizeObserver.disconnect();
      window.removeEventListener("resize", positionMenu);
      window.removeEventListener("scroll", positionMenu, true);
      window.visualViewport?.removeEventListener("resize", positionMenu);
      window.visualViewport?.removeEventListener("scroll", positionMenu);
      document.removeEventListener("mousedown", handleClickOutside);
      document.removeEventListener("keydown", handleEscape, true);
    };
  }, [isOpen, onClose, positionMenu, anchorRef, openSubmenuIndex]);

  useEffect(() => {
    if (isOpen) {
      setSearchQuery("");
      setFocusIndex(-1);
      setOpenSubmenuIndex(null);
      setSubmenuFocusIndex(-1);
      if (searchable) {
        requestAnimationFrame(() => searchRef.current?.focus());
      }
    }
  }, [isOpen, searchable]);

  // WebView2 can latch wheel events onto clipped descendants, so a long menu sometimes does
  // not scroll under the pointer; apply the delta to the menu's own scroller instead.
  useEffect(() => {
    if (!isOpen) return;
    let unbind: (() => void) | undefined;
    const bind = () => {
      const menu = menuRef.current;
      if (menu) unbind = bindScrollContainerWheel(menu);
      return menu !== null;
    };
    const frame = bind() ? 0 : requestAnimationFrame(bind);
    return () => {
      cancelAnimationFrame(frame);
      unbind?.();
    };
  }, [isOpen]);

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      const items = enabledMenuItems(getFilteredItems());
      if (items.length === 0) return;

      // While a submenu is keyboard-open, navigation targets its rows; ArrowLeft returns
      // to the parent row instead of leaving the menu, like IDEA's JMenu.
      if (openSubmenuIndex != null) {
        const submenuItems = enabledMenuItems(items[openSubmenuIndex]?.children ?? []);
        if (submenuItems.length === 0) {
          setOpenSubmenuIndex(null);
          return;
        }
        switch (e.key) {
          case "ArrowDown": {
            e.preventDefault();
            setSubmenuFocusIndex((prev) => (prev + 1) % submenuItems.length);
            return;
          }
          case "ArrowUp": {
            e.preventDefault();
            setSubmenuFocusIndex((prev) => (prev <= 0 ? submenuItems.length - 1 : prev - 1));
            return;
          }
          case "Home": {
            e.preventDefault();
            setSubmenuFocusIndex(0);
            return;
          }
          case "End": {
            e.preventDefault();
            setSubmenuFocusIndex(submenuItems.length - 1);
            return;
          }
          case "ArrowLeft": {
            e.preventDefault();
            setOpenSubmenuIndex(null);
            return;
          }
          case "ArrowRight": {
            // Nested submenus stay pointer-driven; keep focus inside this submenu.
            e.preventDefault();
            return;
          }
          case "Enter": {
            e.preventDefault();
            const child = submenuItems[submenuFocusIndex];
            if (child && !child.children?.length) {
              child.onClick();
              if (closeOnSelect) onClose();
              else setOpenSubmenuIndex(null);
            }
            return;
          }
        }
        return;
      }

      switch (e.key) {
        case "ArrowDown": {
          e.preventDefault();
          setFocusIndex((prev) => (prev + 1) % items.length);
          break;
        }
        case "ArrowUp": {
          e.preventDefault();
          setFocusIndex((prev) => (prev <= 0 ? items.length - 1 : prev - 1));
          break;
        }
        case "Home": {
          e.preventDefault();
          setFocusIndex(0);
          break;
        }
        case "End": {
          e.preventDefault();
          setFocusIndex(items.length - 1);
          break;
        }
        case "ArrowRight": {
          const item = focusIndex >= 0 && focusIndex < items.length ? items[focusIndex] : null;
          if (item && enabledMenuItems(item.children ?? []).length > 0) {
            e.preventDefault();
            setOpenSubmenuIndex(focusIndex);
            setSubmenuFocusIndex(0);
          }
          break;
        }
        case "Enter": {
          e.preventDefault();
          if (focusIndex >= 0 && focusIndex < items.length) {
            const item = items[focusIndex];
            if (enabledMenuItems(item.children ?? []).length > 0) {
              // A submenu row opens its submenu instead of running its no-op click handler.
              setOpenSubmenuIndex(focusIndex);
              setSubmenuFocusIndex(0);
            } else {
              item.onClick();
              if (closeOnSelect) {
                onClose();
              }
            }
          }
          break;
        }
      }
    },
    [closeOnSelect, getFilteredItems, focusIndex, onClose, openSubmenuIndex, submenuFocusIndex],
  );

  if (typeof document === "undefined") return null;

  const originMap: Record<string, string> = {
    "bottom-start": "top left",
    "bottom-end": "top right",
    "top-start": "bottom left",
    "top-end": "bottom right",
  };
  const transformOrigin =
    originMap[`${resolvedSide}-${anchorAlign}`] ?? (point ? "top left" : "top left");

  const filteredItems = hasItems ? getFilteredItems() : [];
  const itemFocusIndex = translateKeyboardFocus(filteredItems, focusIndex).localFocusIndex;
  const itemSubmenuListIndex = translateKeyboardFocus(
    filteredItems,
    openSubmenuIndex ?? -1,
  ).localFocusIndex;
  const itemsActiveSubmenu =
    itemSubmenuListIndex >= 0
      ? { listIndex: itemSubmenuListIndex, childFocusIndex: submenuFocusIndex }
      : null;
  const filteredSections = hasSections ? getFilteredSections() : [];
  let enabledBefore = 0;
  const sectionKeyboard = filteredSections.map((section) => {
    const { localFocusIndex, enabledCount } = translateKeyboardFocus(
      section.items,
      focusIndex - enabledBefore,
    );
    const submenuListIndex = translateKeyboardFocus(
      section.items,
      (openSubmenuIndex ?? -1) - enabledBefore,
    ).localFocusIndex;
    enabledBefore += enabledCount;
    return { focusIndex: localFocusIndex, submenuListIndex };
  });

  return (
    <FloatingPopoverContent
      isOpen={isOpen}
      contentRef={menuRef}
      portalContainer={portalContainer}
      className={className}
      style={{ transformOrigin, visibility: isPositioned ? "visible" : "hidden", ...style }}
      animated={animated}
      initial={{
        opacity: 0,
        scale: 0.98,
        y: resolvedSide === "top" ? 4 : -4,
        filter: "blur(2px)",
      }}
      animate={{ opacity: 1, scale: 1, y: 0, filter: "blur(0px)" }}
      exit={{
        opacity: 0,
        scale: 0.98,
        y: resolvedSide === "top" ? 4 : -4,
        filter: "blur(2px)",
      }}
      transition={quickTransition}
    >
      <div role="menu" className={menuClassName} onKeyDown={handleKeyDown}>
        {searchable && (
          <div className="border-border/60 border-b px-1.5 pb-1.5 pt-0.5">
            <Input
              ref={searchRef}
              type="text"
              placeholder={searchPlaceholder ?? t("ui.searchPlaceholder")}
              value={searchQuery}
              onChange={(e) => {
                setSearchQuery(e.target.value);
                setFocusIndex(-1);
                setOpenSubmenuIndex(null);
              }}
              leftIcon={Search}
              variant="ghost"
              className="w-full"
            />
          </div>
        )}
        {hasChildren && (props as ChildrenContent).children}
        {hasItems && (
          <MenuItemsList
            items={filteredItems}
            focusIndex={itemFocusIndex}
            activeSubmenu={itemsActiveSubmenu}
            onItemSelect={closeOnSelect ? onClose : undefined}
            density={density}
            showIcons={showIcons}
          />
        )}
        {hasSections &&
          filteredSections.map((section, sectionIdx) => (
            <div key={section.id}>
              {sectionIdx > 0 && <div className="my-0.5 border-border/70 border-t" />}
              {section.label && (
                <div className={dropdownSectionLabelVariants({ density })}>{section.label}</div>
              )}
              <MenuItemsList
                items={section.items}
                focusIndex={sectionKeyboard[sectionIdx].focusIndex}
                activeSubmenu={
                  sectionKeyboard[sectionIdx].submenuListIndex >= 0
                    ? {
                        listIndex: sectionKeyboard[sectionIdx].submenuListIndex,
                        childFocusIndex: submenuFocusIndex,
                      }
                    : null
                }
                onItemSelect={closeOnSelect ? onClose : undefined}
                density={density}
                showIcons={showIcons}
              />
            </div>
          ))}
      </div>
    </FloatingPopoverContent>
  );
}

function DropdownMenu(props: DropdownMenuPrimitive.Root.Props) {
  return <DropdownMenuPrimitive.Root data-slot="dropdown-menu" {...props} />;
}

function DropdownMenuPortal(props: DropdownMenuPrimitive.Portal.Props) {
  return <DropdownMenuPrimitive.Portal data-slot="dropdown-menu-portal" {...props} />;
}

function DropdownMenuTrigger(props: DropdownMenuPrimitive.Trigger.Props) {
  return <DropdownMenuPrimitive.Trigger data-slot="dropdown-menu-trigger" {...props} />;
}

type DropdownMenuContentProps = DropdownMenuPrimitive.Popup.Props &
  Pick<
    DropdownMenuPrimitive.Positioner.Props,
    "align" | "alignOffset" | "side" | "sideOffset" | "collisionPadding"
  >;

function DropdownMenuContent({
  className,
  align = "end",
  alignOffset,
  side = "bottom",
  sideOffset = 4,
  collisionPadding = 8,
  ...props
}: DropdownMenuContentProps) {
  return (
    <DropdownMenuPrimitive.Portal>
      <DropdownMenuPrimitive.Positioner
        align={align}
        alignOffset={alignOffset}
        side={side}
        sideOffset={sideOffset}
        collisionPadding={collisionPadding}
        className="isolate z-10070 outline-none"
      >
        <DropdownMenuPrimitive.Popup
          data-slot="dropdown-menu-content"
          className={cn(
            "z-10070 max-h-(--available-height) min-w-44 origin-(--transform-origin) overflow-x-hidden overflow-y-auto rounded-md bg-surface p-1 font-sans ui-text-sm text-foreground shadow-(--shadow-popover) ring-1 ring-border/70 duration-100 outline-none data-[side=bottom]:slide-in-from-top-2 data-[side=left]:slide-in-from-right-2 data-[side=right]:slide-in-from-left-2 data-[side=top]:slide-in-from-bottom-2 data-open:animate-in data-open:fade-in-0 data-open:zoom-in-95 data-closed:animate-out data-closed:fade-out-0 data-closed:zoom-out-95",
            className,
          )}
          {...props}
        />
      </DropdownMenuPrimitive.Positioner>
    </DropdownMenuPrimitive.Portal>
  );
}

function DropdownMenuGroup(props: DropdownMenuPrimitive.Group.Props) {
  return <DropdownMenuPrimitive.Group data-slot="dropdown-menu-group" {...props} />;
}

function DropdownMenuItem({
  className,
  inset,
  variant = "default",
  ...props
}: DropdownMenuPrimitive.Item.Props & {
  inset?: boolean;
  variant?: "default" | "destructive";
}) {
  return (
    <DropdownMenuPrimitive.Item
      data-slot="dropdown-menu-item"
      data-inset={inset}
      data-variant={variant}
      className={cn(
        "group/dropdown-menu-item relative flex cursor-default items-center gap-2 rounded-sm px-2 py-1.5 outline-hidden select-none focus:bg-accent focus:text-foreground data-inset:pl-8 data-[variant=destructive]:text-destructive data-[variant=destructive]:focus:bg-destructive/10 data-disabled:pointer-events-none data-disabled:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4 data-[variant=destructive]:*:[svg]:text-destructive",
        className,
      )}
      {...props}
    />
  );
}

function DropdownMenuCheckboxItem({
  className,
  children,
  checked,
  inset,
  ...props
}: DropdownMenuPrimitive.CheckboxItem.Props & { inset?: boolean }) {
  return (
    <DropdownMenuPrimitive.CheckboxItem
      data-slot="dropdown-menu-checkbox-item"
      data-inset={inset}
      className={cn(
        "relative flex cursor-default items-center gap-2 rounded-sm py-1.5 pr-8 pl-2 outline-hidden select-none focus:bg-accent focus:text-foreground data-inset:pl-8 data-disabled:pointer-events-none data-disabled:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className,
      )}
      checked={checked}
      {...props}
    >
      <span className="pointer-events-none absolute right-2 flex size-4 items-center justify-center">
        <DropdownMenuPrimitive.CheckboxItemIndicator>
          <CheckIcon />
        </DropdownMenuPrimitive.CheckboxItemIndicator>
      </span>
      {children}
    </DropdownMenuPrimitive.CheckboxItem>
  );
}

function DropdownMenuRadioGroup(props: DropdownMenuPrimitive.RadioGroup.Props) {
  return <DropdownMenuPrimitive.RadioGroup data-slot="dropdown-menu-radio-group" {...props} />;
}

function DropdownMenuRadioItem({
  className,
  children,
  inset,
  ...props
}: DropdownMenuPrimitive.RadioItem.Props & { inset?: boolean }) {
  return (
    <DropdownMenuPrimitive.RadioItem
      data-slot="dropdown-menu-radio-item"
      data-inset={inset}
      className={cn(
        "relative flex cursor-default items-center gap-2 rounded-sm py-1.5 pr-8 pl-2 outline-hidden select-none focus:bg-accent focus:text-foreground data-inset:pl-8 data-disabled:pointer-events-none data-disabled:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className,
      )}
      {...props}
    >
      <span className="pointer-events-none absolute right-2 flex size-4 items-center justify-center">
        <DropdownMenuPrimitive.RadioItemIndicator>
          <CheckIcon />
        </DropdownMenuPrimitive.RadioItemIndicator>
      </span>
      {children}
    </DropdownMenuPrimitive.RadioItem>
  );
}

function DropdownMenuLabel({
  className,
  inset,
  ...props
}: DropdownMenuPrimitive.GroupLabel.Props & { inset?: boolean }) {
  return (
    <DropdownMenuPrimitive.GroupLabel
      data-slot="dropdown-menu-label"
      data-inset={inset}
      className={cn("px-2 py-1.5 font-medium text-subtle-foreground data-inset:pl-8", className)}
      {...props}
    />
  );
}

function DropdownMenuSeparator({ className, ...props }: DropdownMenuPrimitive.Separator.Props) {
  return (
    <DropdownMenuPrimitive.Separator
      data-slot="dropdown-menu-separator"
      className={cn("-mx-1 my-1 h-px bg-border", className)}
      {...props}
    />
  );
}

function DropdownMenuShortcut({ className, ...props }: ComponentProps<"span">) {
  return (
    <span
      data-slot="dropdown-menu-shortcut"
      className={cn(
        "ml-auto tracking-widest text-subtle-foreground group-focus/dropdown-menu-item:text-foreground",
        className,
      )}
      {...props}
    />
  );
}

function DropdownMenuSub(props: DropdownMenuPrimitive.SubmenuRoot.Props) {
  return <DropdownMenuPrimitive.SubmenuRoot data-slot="dropdown-menu-sub" {...props} />;
}

function DropdownMenuSubTrigger({
  className,
  inset,
  children,
  ...props
}: DropdownMenuPrimitive.SubmenuTrigger.Props & { inset?: boolean }) {
  return (
    <DropdownMenuPrimitive.SubmenuTrigger
      data-slot="dropdown-menu-sub-trigger"
      data-inset={inset}
      className={cn(
        "flex cursor-default items-center gap-2 rounded-sm px-2 py-1.5 outline-hidden select-none focus:bg-accent focus:text-foreground data-inset:pl-8 data-open:bg-accent data-open:text-foreground [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className,
      )}
      {...props}
    >
      {children}
      <CaretRightIcon className="ml-auto" />
    </DropdownMenuPrimitive.SubmenuTrigger>
  );
}

function DropdownMenuSubContent(props: DropdownMenuContentProps) {
  return (
    <DropdownMenuContent
      data-slot="dropdown-menu-sub-content"
      side="right"
      className="shadow-(--shadow-popover)"
      {...props}
    />
  );
}

export {
  DropdownMenu,
  DropdownMenuCheckboxItem,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuPortal,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuShortcut,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
  DropdownMenuTrigger,
};
