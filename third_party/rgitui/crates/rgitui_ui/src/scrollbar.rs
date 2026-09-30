use std::cell::Cell;
use std::rc::Rc;

use gpui::{
    fill, hsla, point, px, size, Along, App, Axis, Bounds, DispatchPhase, Element, ElementId,
    GlobalElementId, Hitbox, HitboxBehavior, InspectorElementId, LayoutId, ListOffset, ListState,
    MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, Pixels, Point, ScrollHandle, Style,
    UniformListScrollHandle, Window,
};
use rgitui_theme::ActiveTheme;

const THICKNESS: Pixels = px(10.);
const MIN_THUMB_LEN: Pixels = px(24.);

/// Persisted thumb-drag state for a [`Scrollbar`] element.
///
/// Stored via [`Window::with_element_state`] so the grab offset survives the
/// re-renders that can occur mid-drag. The inner [`Cell`] is shared (via
/// [`Rc`]) with the mouse-event listeners registered each paint, which read and
/// write the active drag's thumb-local offset.
#[derive(Default)]
struct ThumbDragState {
    /// `Some(thumb_local)` while a drag is active, where `thumb_local` is the
    /// distance between the grab point and the thumb's leading edge along the
    /// scrollbar axis. `None` when no drag is in progress.
    offset: Rc<Cell<Option<Pixels>>>,
}

/// Abstraction over scrollable containers so [`Scrollbar`] can drive either a
/// flex container (`ScrollHandle`) or a virtualized list (`ListState`).
///
/// Implementations are expected to be cheap to clone — the scrollbar grabs a
/// handle during prepaint and retains it inside mouse event callbacks.
pub trait ScrollableHandle: 'static + Clone {
    /// Maximum scroll offset along both axes. A zero value means "no scroll".
    fn max_offset(&self) -> Point<Pixels>;
    /// Current scroll offset. Negative values indicate content scrolled past
    /// the top/left edge.
    fn offset(&self) -> Point<Pixels>;
    /// Apply a new scroll offset.
    fn set_offset(&self, point: Point<Pixels>);
    /// Current viewport bounds in window coordinates.
    fn viewport(&self) -> Bounds<Pixels>;
    /// Called when the user begins a thumb drag. Implementations that cache
    /// content height during a drag (to keep the thumb stable) hook here.
    fn drag_started(&self) {}
    /// Called when the user ends a thumb drag.
    fn drag_ended(&self) {}
}

impl ScrollableHandle for ScrollHandle {
    fn max_offset(&self) -> Point<Pixels> {
        ScrollHandle::max_offset(self)
    }

    fn offset(&self) -> Point<Pixels> {
        ScrollHandle::offset(self)
    }

    fn set_offset(&self, point: Point<Pixels>) {
        ScrollHandle::set_offset(self, point);
    }

    fn viewport(&self) -> Bounds<Pixels> {
        ScrollHandle::bounds(self)
    }
}

impl ScrollableHandle for UniformListScrollHandle {
    fn max_offset(&self) -> Point<Pixels> {
        self.0.borrow().base_handle.max_offset()
    }

    fn offset(&self) -> Point<Pixels> {
        self.0.borrow().base_handle.offset()
    }

    fn set_offset(&self, point: Point<Pixels>) {
        self.0.borrow().base_handle.set_offset(point);
    }

    fn viewport(&self) -> Bounds<Pixels> {
        self.0.borrow().base_handle.bounds()
    }
}

impl ScrollableHandle for ListState {
    fn max_offset(&self) -> Point<Pixels> {
        self.max_offset_for_scrollbar()
    }

    fn offset(&self) -> Point<Pixels> {
        self.scroll_px_offset_for_scrollbar()
    }

    fn set_offset(&self, point: Point<Pixels>) {
        self.set_offset_from_scrollbar(point);
    }

    fn viewport(&self) -> Bounds<Pixels> {
        self.viewport_bounds()
    }

    fn drag_started(&self) {
        self.scrollbar_drag_started();
    }

    fn drag_ended(&self) {
        self.scrollbar_drag_ended();
    }
}

/// A [`ScrollableHandle`] for a [`ListState`] that derives scrollbar geometry from
/// a fixed per-row height estimate rather than `ListState`'s measured content
/// height.
///
/// `ListState` measures item heights lazily as rows scroll into view, so its
/// reported content height grows while you scroll — a scrollbar driven directly
/// off it resizes its thumb mid-scroll. Modelling content as
/// `row_count * row_height` keeps the thumb a constant size. The mapped position
/// is exact for rows that occupy a single line and approximate for rows that wrap
/// to several visual lines, which is an acceptable trade for a stable, grabbable
/// thumb (line wrapping is opt-in).
#[derive(Clone)]
pub struct EstimatedListScroll {
    list: ListState,
    row_count: usize,
    row_height: Pixels,
}

impl EstimatedListScroll {
    pub fn new(list: ListState, row_count: usize, row_height: Pixels) -> Self {
        Self {
            list,
            row_count,
            row_height,
        }
    }

    fn content_height(&self) -> Pixels {
        self.row_height * self.row_count as f32
    }
}

impl ScrollableHandle for EstimatedListScroll {
    fn max_offset(&self) -> Point<Pixels> {
        let viewport = self.list.viewport_bounds().size.height;
        point(
            Pixels::ZERO,
            (self.content_height() - viewport).max(Pixels::ZERO),
        )
    }

    fn offset(&self) -> Point<Pixels> {
        let top = self.list.logical_scroll_top();
        // Clamp the intra-item pixel offset to one estimated row: a wrapped row
        // (taller than the estimate) at the viewport top must not push the
        // modelled offset past the next row boundary and overshoot max_offset.
        let intra = self.row_height.min(top.offset_in_item);
        let y = self.row_height * top.item_ix as f32 + intra;
        point(Pixels::ZERO, -y)
    }

    fn set_offset(&self, offset: Point<Pixels>) {
        if self.row_count == 0 || self.row_height <= Pixels::ZERO {
            return;
        }
        let target = (-offset.y).max(Pixels::ZERO);
        let item_ix = ((target / self.row_height).floor() as usize).min(self.row_count - 1);
        let offset_in_item = target - self.row_height * item_ix as f32;
        self.list.scroll_to(ListOffset {
            item_ix,
            offset_in_item,
        });
    }

    fn viewport(&self) -> Bounds<Pixels> {
        self.list.viewport_bounds()
    }
}

/// A minimal always-visible scrollbar bound to a [`ScrollableHandle`].
///
/// Place it as a sibling of the scrollable content — its layout reserves a
/// 10px-thick track along `axis`. The thumb size and position are derived
/// from the handle's viewport bounds and max offset each frame; drag on the
/// thumb or click on the track to move the bound content.
pub struct Scrollbar<H: ScrollableHandle> {
    id: ElementId,
    axis: Axis,
    handle: H,
}

impl<H: ScrollableHandle> Scrollbar<H> {
    pub fn horizontal(id: impl Into<ElementId>, handle: H) -> Self {
        Self {
            id: id.into(),
            axis: Axis::Horizontal,
            handle,
        }
    }

    pub fn vertical(id: impl Into<ElementId>, handle: H) -> Self {
        Self {
            id: id.into(),
            axis: Axis::Vertical,
            handle,
        }
    }
}

pub struct ScrollbarPrepaint {
    track: Bounds<Pixels>,
    thumb: Bounds<Pixels>,
    hitbox: Hitbox,
    max_offset: Pixels,
    thumb_travel: Pixels,
    /// True when viewport covers all content — no thumb should paint.
    empty: bool,
}

impl<H: ScrollableHandle> gpui::IntoElement for Scrollbar<H> {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

impl<H: ScrollableHandle> Element for Scrollbar<H> {
    type RequestLayoutState = ();
    type PrepaintState = Option<ScrollbarPrepaint>;

    fn id(&self) -> Option<ElementId> {
        Some(self.id.clone())
    }

    fn source_location(&self) -> Option<&'static core::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, Self::RequestLayoutState) {
        let (width, height) = match self.axis {
            Axis::Horizontal => (gpui::relative(1.).into(), THICKNESS.into()),
            Axis::Vertical => (THICKNESS.into(), gpui::relative(1.).into()),
        };
        let style = Style {
            flex_shrink: 0.,
            flex_grow: 0.,
            size: gpui::Size { width, height },
            ..Default::default()
        };
        (window.request_layout(style, None, cx), ())
    }

    fn prepaint(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _request_layout: &mut Self::RequestLayoutState,
        window: &mut Window,
        _cx: &mut App,
    ) -> Self::PrepaintState {
        let viewport = self.handle.viewport();
        let max_offset = self.handle.max_offset();
        let axis = self.axis;

        let viewport_size = viewport.size.along(axis);
        let max = max_offset.along(axis);
        let content_size = viewport_size + max;

        log::trace!(
            target: "rgitui::scrollbar",
            "prepaint axis={:?} track_bounds={:?} viewport={:?} viewport_size={:?} max_offset={:?} content_size={:?} offset={:?}",
            axis,
            bounds,
            viewport,
            viewport_size,
            max,
            content_size,
            self.handle.offset(),
        );

        if viewport_size <= Pixels::ZERO || content_size <= viewport_size {
            log::trace!(
                target: "rgitui::scrollbar",
                "  -> empty (content fits viewport, nothing to scroll)"
            );
            let hitbox = window.insert_hitbox(bounds, HitboxBehavior::Normal);
            return Some(ScrollbarPrepaint {
                track: bounds,
                thumb: Bounds::default(),
                hitbox,
                max_offset: Pixels::ZERO,
                thumb_travel: Pixels::ZERO,
                empty: true,
            });
        }

        let track_len = bounds.size.along(axis);
        let raw_thumb_len = track_len * (viewport_size / content_size);
        let thumb_len = raw_thumb_len.max(MIN_THUMB_LEN).min(track_len);
        let thumb_travel = (track_len - thumb_len).max(Pixels::ZERO);

        // offset() is negative when scrolled; normalize to [0, max].
        let scrolled = (-self.handle.offset().along(axis))
            .max(Pixels::ZERO)
            .min(max);
        let ratio = if max > Pixels::ZERO {
            scrolled / max
        } else {
            0.
        };
        let thumb_start = thumb_travel * ratio;

        let thumb = match axis {
            Axis::Horizontal => Bounds::new(
                point(bounds.origin.x + thumb_start, bounds.origin.y + px(2.)),
                size(thumb_len, bounds.size.height - px(4.)),
            ),
            Axis::Vertical => Bounds::new(
                point(bounds.origin.x + px(2.), bounds.origin.y + thumb_start),
                size(bounds.size.width - px(4.), thumb_len),
            ),
        };

        log::trace!(
            target: "rgitui::scrollbar",
            "  -> track_len={:?} thumb_len={:?} thumb_travel={:?} scrolled={:?} ratio={:.3} thumb={:?}",
            track_len,
            thumb_len,
            thumb_travel,
            scrolled,
            ratio,
            thumb,
        );

        let hitbox = window.insert_hitbox(bounds, HitboxBehavior::Normal);

        Some(ScrollbarPrepaint {
            track: bounds,
            thumb,
            hitbox,
            max_offset: max,
            thumb_travel,
            empty: false,
        })
    }

    fn paint(
        &mut self,
        id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        _bounds: Bounds<Pixels>,
        _request_layout: &mut Self::RequestLayoutState,
        prepaint: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        let Some(state) = prepaint.as_ref() else {
            return;
        };

        let colors = cx.colors();
        let track_bg = hsla(0., 0., 0., 0.);
        let thumb_bg = colors.scrollbar_thumb_background;
        let thumb_hover = colors.scrollbar_thumb_hover_background;

        window.paint_quad(fill(state.track, track_bg));
        if state.empty {
            return;
        }

        let hovering = state.hitbox.is_hovered(window);
        let thumb_color = if hovering { thumb_hover } else { thumb_bg };
        window.paint_quad(fill(state.thumb, thumb_color).corner_radii(gpui::Corners::all(px(3.))));

        // Persist the thumb-local grab offset in GPUI element state so it survives
        // re-renders that occur mid-drag (hover events, watcher polls, cursor
        // blink). A per-paint cell would be reset to `None` by any such repaint —
        // GPUI carries over `element_states` across frames but not mouse listeners,
        // so the drag offset must live in element state to keep the thumb tracking.
        let drag_state = id
            .map(|id| {
                window.with_element_state::<ThumbDragState, _>(id, |existing, _window| {
                    let state = existing.unwrap_or_default();
                    (state.offset.clone(), state)
                })
            })
            .unwrap_or_default();
        let axis = self.axis;
        let handle = self.handle.clone();
        let thumb_bounds = state.thumb;
        let track_bounds = state.track;
        let track_origin = track_bounds.origin.along(axis);
        let thumb_len = thumb_bounds.size.along(axis);
        let thumb_travel = state.thumb_travel;
        let max_offset = state.max_offset;

        let offset_for_thumb_start = {
            let handle = handle.clone();
            move |thumb_start: Pixels| -> Point<Pixels> {
                let ratio = if thumb_travel > Pixels::ZERO {
                    (thumb_start / thumb_travel).clamp(0., 1.)
                } else {
                    0.
                };
                let scrolled = max_offset * ratio;
                let mut offset = handle.offset();
                match axis {
                    Axis::Horizontal => offset.x = -scrolled,
                    Axis::Vertical => offset.y = -scrolled,
                }
                offset
            }
        };

        // Mouse down on thumb → start drag, recording thumb-local offset.
        // Mouse down on track (outside thumb) → jump so thumb centers on click.
        {
            let drag_state = drag_state.clone();
            let hitbox = state.hitbox.clone();
            let handle = handle.clone();
            let offset_for_thumb_start = offset_for_thumb_start.clone();
            window.on_mouse_event(move |event: &MouseDownEvent, phase, window, cx| {
                if phase != DispatchPhase::Bubble {
                    return;
                }
                if event.button != MouseButton::Left {
                    return;
                }
                if !hitbox.is_hovered(window) {
                    return;
                }
                let pos = event.position.along(axis);
                handle.drag_started();
                if thumb_bounds.contains(&event.position) {
                    drag_state.set(Some(pos - thumb_bounds.origin.along(axis)));
                } else {
                    let thumb_start =
                        (pos - track_origin - thumb_len / 2.).clamp(px(0.), thumb_travel);
                    let new_offset = offset_for_thumb_start(thumb_start);
                    handle.set_offset(new_offset);
                    drag_state.set(Some(thumb_len / 2.));
                }
                window.refresh();
                cx.stop_propagation();
            });
        }

        {
            let drag_state = drag_state.clone();
            let handle = handle.clone();
            let offset_for_thumb_start = offset_for_thumb_start.clone();
            let drag_phase = if drag_state.get().is_some() {
                DispatchPhase::Capture
            } else {
                DispatchPhase::Bubble
            };
            window.on_mouse_event(move |event: &MouseMoveEvent, phase, window, cx| {
                if phase != drag_phase {
                    return;
                }
                let Some(local) = drag_state.get() else {
                    return;
                };
                let pos = event.position.along(axis);
                let thumb_start = (pos - track_origin - local).clamp(px(0.), thumb_travel);
                let new_offset = offset_for_thumb_start(thumb_start);
                handle.set_offset(new_offset);
                window.refresh();
                cx.stop_propagation();
            });
        }

        {
            let handle = handle.clone();
            let drag_state = drag_state.clone();
            let drag_phase = if drag_state.get().is_some() {
                DispatchPhase::Capture
            } else {
                DispatchPhase::Bubble
            };
            window.on_mouse_event(move |event: &MouseUpEvent, phase, window, cx| {
                if phase != drag_phase {
                    return;
                }
                if event.button != MouseButton::Left {
                    return;
                }
                if drag_state.take().is_some() {
                    handle.drag_ended();
                    window.refresh();
                    cx.stop_propagation();
                }
            });
        }
    }
}
