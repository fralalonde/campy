//! The renderer every Campy window is drawn through, and how it presents.
//!
//! zgui's own factory is the default; Campy replaces it to choose one thing:
//! the present pacing. Everything else here mirrors `zgui::app::graphics` —
//! one shared graphics device for all windows, the vector rasteriser attached,
//! buffer crops and group precision handed through — so the frames this draws
//! are the frames a stock application would draw.
//!
//! # Why Campy chooses the pacing
//!
//! [`PresentPacing::Display`] makes the graphics API wait for the display
//! inside the surface acquisition (wgpu's `Fifo`). That wait happens on the UI
//! thread — the same thread that answers pointer input and runs the command
//! drain — so a window presenting at 20 frames a second also *handles input*
//! 20 times a second. Measured on a 1280×860 window at scale 1.4 while dragging
//! a component: 22–50 ms inside `get_current_texture` per presented frame, with
//! the compositor and the process both idle; the editor's own work for the
//! same frame was ~1 ms. The drag ran at 20–25 updates a second.
//!
//! [`PresentPacing::Platform`] presents without waiting (`Mailbox`, falling
//! back to `Immediate`): a composed frame is handed over and the loop stays
//! free to take the next pointer event. The same drag then ran at the rate the
//! pointer produced it (5× faster in the measurement) with the window's own
//! cost unchanged, and an idle window still draws nothing. Campy animates
//! nothing that needs the display's cadence, so on a Wayland surface the
//! non-blocking path is the default. `CAMPY_UI_PACING=display|platform`
//! overrides it for an A/B.

use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};

use zgui::platform::Surface;
use zgui::runtime::RendererFactory;
use zgui_render_wgpu::{GroupPrecision, PresentPacing, SharedGraphics};

/// How this surface should present.
fn pacing(surface: &Arc<dyn Surface>) -> PresentPacing {
    choose(
        std::env::var("CAMPY_UI_PACING").ok().as_deref(),
        matches!(
            surface.present_pacing(),
            zgui::platform::PresentPacing::Platform
        ),
        std::env::var_os("WAYLAND_DISPLAY").is_some(),
    )
}

/// The pacing decision itself, apart from the environment it is read from.
fn choose(overridden: Option<&str>, surface_paces: bool, wayland: bool) -> PresentPacing {
    match overridden.map(str::trim) {
        Some("display") => return PresentPacing::Display,
        Some("platform") => return PresentPacing::Platform,
        _ => (),
    }
    // A platform that paces frames itself must not be blocked by the API.
    if surface_paces {
        return PresentPacing::Platform;
    }
    // winit leaves the wait to the display; on Wayland that wait is paid on
    // the input thread, which is the cost this factory exists to avoid.
    if wayland {
        return PresentPacing::Platform;
    }
    PresentPacing::Display
}

#[cfg(test)]
mod tests {
    use super::{PresentPacing, choose};

    #[test]
    fn a_wayland_window_presents_without_waiting() {
        // The wait for the display happens on the thread that answers input;
        // on Wayland Campy takes the non-blocking path.
        assert_eq!(choose(None, false, true), PresentPacing::Platform);
    }

    #[test]
    fn a_surface_that_paces_itself_is_never_blocked() {
        assert_eq!(choose(None, true, false), PresentPacing::Platform);
    }

    #[test]
    fn a_display_paced_surface_elsewhere_keeps_vsync() {
        assert_eq!(choose(None, false, false), PresentPacing::Display);
    }

    #[test]
    fn the_environment_can_ask_for_either() {
        assert_eq!(choose(Some("display"), false, true), PresentPacing::Display);
        assert_eq!(
            choose(Some("platform"), false, false),
            PresentPacing::Platform
        );
        assert_eq!(
            choose(Some("unrelated"), false, false),
            PresentPacing::Display
        );
    }
}

/// The renderer factory an application's windows are drawn through.
///
/// `snapshot` names a PNG to write once the window has settled (see
/// [`crate::snapshot`]); without one the renderer is the plain one.
pub fn factory(snapshot: Option<std::path::PathBuf>) -> RendererFactory {
    let graphics = SharedGraphics::new();
    let precision = GroupPrecision::from_environment().unwrap_or_default();
    // One counter across windows: the initial window takes the plain name and
    // each later one a suffix, so a preview window does not overwrite the IDE.
    let opened = AtomicU32::new(0);
    Box::new(move |surface, target| {
        let handles = Arc::clone(surface).gpu_shared().ok_or_else(|| {
            zgui::runtime::AppError::Platform(zgui::platform::PlatformError::Backend(
                "this window offers no handles a graphics API can draw into".to_owned(),
            ))
        })?;
        let pacing = pacing(&surface);
        let mut renderer = graphics
            .renderer_for_surface(target, handles, pacing, None)
            .map_err(zgui::runtime::AppError::GpuUnavailable)?;
        // A platform that paces its own frames also decides when a composed
        // frame is handed over. winit's surface is always ready.
        if pacing == PresentPacing::Platform {
            let gate = Arc::clone(&surface);
            renderer.set_present_gate(Box::new(move || gate.present_now()));
        }
        if std::env::var_os("CAMPY_UI_FRAME_LOG").is_some() {
            eprintln!("campy present: pacing={pacing:?} target={target:?}");
        }
        renderer.set_crops_buffers(surface.crops_buffers());
        renderer.set_group_precision(precision);
        // Without this a display list's vector passes are planned, counted and
        // then drawn from nothing: every drawing in the window would be empty
        // space.
        zgui_render_vector_vello::attach(&mut renderer, target.size);
        let index = opened.fetch_add(1, Ordering::Relaxed);
        Ok(match &snapshot {
            Some(path) => crate::snapshot::recorder(renderer, path.clone(), index),
            None => Box::new(renderer),
        })
    })
}
