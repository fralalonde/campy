//! Debug screenshots of the live window, and the self-click probe.
//!
//! The renderer factory that wraps a window in a recorder lives in
//! [`crate::graphics`], beside the pacing policy; this module owns the frame
//! readback (below) and the platform-event probe at the bottom.
//!
//! `CAMPY_UI_SNAPSHOT=/tmp/opencode/ide.png` wraps each window's renderer in a
//! thin recorder that copies the composed frame back once the window has
//! settled and writes it as a PNG. The window keeps drawing normally; the
//! only cost is one device readback.
//!
//! Why in-process: on a Wayland session nothing outside the process may read
//! its pixels. KWin's `ScreenShot2` interface answers only
//! `xdg-desktop-portal-kde` (`NoAuthorized` to everyone else), the portal
//! prompts a human, and `grim`/`ydotool` are not installed. The frame the
//! window composed *is* what the user sees, so reading it here needs no
//! permission and no compositor support.
//!
//! `CAMPY_UI_SNAPSHOT_DELAY_MS` (default 2500) sets how long after the
//! renderer opens the frame is taken, so that fonts and the first full
//! repaint have landed.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use zgui::bits::DamageSet;
use zgui::geom::{Css, CssPx, Point};
use zgui::platform::{AppHandler, IdlePolicy, PlatformCx, SurfaceEvent, SurfaceId, WakeReason};
use zgui::render::{RenderTarget, Renderer};
use zgui::vocab::{Modifiers, PointerAction, PointerButton, PointerEvent};
use zgui_render_wgpu::{Pixels, WgpuRenderer};

/// The environment variable naming the PNG to write.
pub const ENV: &str = "CAMPY_UI_SNAPSHOT";

/// A monotonic clock shared by the diagnostics, in milliseconds.
fn clock() -> f64 {
    static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
    let start = START.get_or_init(Instant::now);
    start.elapsed().as_secs_f64() * 1000.0
}

/// Prints how long `what` took, when the frame log is on and it took more than
/// a millisecond. A listener that waits on another thread shows up here.
pub fn slow(what: &str, began: Instant) {
    if std::env::var_os("CAMPY_UI_FRAME_LOG").is_some() {
        let micros = began.elapsed().as_micros();
        if micros > 1000 {
            eprintln!("campy {what}: {micros}us");
        }
    }
}

/// Prints one timeline line when the frame log is on, so a gesture can be read
/// against the frames it produced (`CAMPY_UI_FRAME_LOG=1`).
pub fn trace(tag: &str) {
    if std::env::var_os("CAMPY_UI_FRAME_LOG").is_some() {
        eprintln!("campy {tag} at {:.1}", clock());
    }
}
/// A file whose existence asks for one more frame to be written, then removed.
///
/// The timed frame above catches the settled startup state; this catches
/// states that only exist after an interaction, without making an interactive
/// session write a frame every tick.
const TRIGGER_ENV: &str = "CAMPY_UI_SNAPSHOT_TRIGGER";
/// How long a window may settle before its frame is taken.
const DELAY_ENV: &str = "CAMPY_UI_SNAPSHOT_DELAY_MS";
const DEFAULT_DELAY: Duration = Duration::from_millis(2500);

/// The requested screenshot path, if screenshots are on.
pub fn path() -> Option<PathBuf> {
    std::env::var_os(ENV).map(PathBuf::from)
}

/// The on-demand trigger, if one was configured.
fn trigger() -> Option<PathBuf> {
    std::env::var_os(TRIGGER_ENV).map(PathBuf::from)
}

fn delay() -> Duration {
    std::env::var(DELAY_ENV)
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .map(Duration::from_millis)
        .unwrap_or(DEFAULT_DELAY)
}

/// Wraps `inner` so one settled frame is copied out as PNG number `index`.
pub fn recorder(inner: WgpuRenderer, path: PathBuf, index: u32) -> Box<dyn Renderer> {
    Box::new(Snapshot {
        inner,
        path: numbered(&path, index),
        due: Instant::now() + delay(),
        taken: false,
        trigger: trigger(),
        asked: 0,
    })
}

/// `ide.png` for the first window, `ide-2.png` for the second, and so on.
fn numbered(path: &Path, index: u32) -> PathBuf {
    if index == 0 {
        return path.to_path_buf();
    }
    let stem = path
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_else(|| "campy-ui".to_owned());
    let extension = path
        .extension()
        .map(|extension| format!(".{}", extension.to_string_lossy()))
        .unwrap_or_default();
    path.with_file_name(format!("{stem}-{}{extension}", index + 1))
}

/// The window's real renderer, with one frame copied out on the way past.
struct Snapshot {
    inner: WgpuRenderer,
    path: PathBuf,
    due: Instant,
    taken: bool,
    /// Watched for between frames: what asks for a frame *now*.
    trigger: Option<PathBuf>,
    /// How many frames the trigger has asked for.
    asked: u32,
}

impl Renderer for Snapshot {
    fn capabilities(&self) -> zgui::render::RenderCapabilities {
        self.inner.capabilities()
    }

    fn configure(&mut self, target: RenderTarget) {
        self.inner.configure(target);
    }

    fn target(&self) -> Option<RenderTarget> {
        self.inner.target()
    }

    fn draw(
        &mut self,
        scene: &zgui::scene::Scene,
        damage: &DamageSet,
    ) -> zgui::render::FrameOutcome {
        let outcome = self.inner.draw(scene, damage);
        if !self.taken && Instant::now() >= self.due {
            self.taken = true;
            self.capture(&self.path.clone());
        }
        if let Some(trigger) = &self.trigger
            && trigger.exists()
        {
            // Consumed first: a frame that is written because the file existed
            // must not be written twice if the removal is slow.
            let _ = std::fs::remove_file(trigger);
            self.asked += 1;
            let path = self.path.with_file_name(format!(
                "{}-shot{}.png",
                self.path
                    .file_stem()
                    .map(|stem| stem.to_string_lossy().into_owned())
                    .unwrap_or_else(|| "campy-ui".to_owned()),
                self.asked
            ));
            self.capture(&path);
        }
        outcome
    }

    fn shifts_composed_pixels(&self) -> bool {
        self.inner.shifts_composed_pixels()
    }

    fn set_subpixel_order(&mut self, order: zgui::render::SubpixelOrder) {
        self.inner.set_subpixel_order(order);
    }

    fn composed_survives_configure(&self) -> bool {
        self.inner.composed_survives_configure()
    }

    fn shift_composed(&mut self, shift: zgui::render::ScrollShift) {
        self.inner.shift_composed(shift);
    }

    fn register_external(
        &mut self,
        texture: zgui::render::ExternalTexture,
    ) -> zgui::render::TextureHandle {
        self.inner.register_external(texture)
    }

    fn release_external(&mut self, handle: zgui::render::TextureHandle) {
        self.inner.release_external(handle);
    }

    fn memory(&self) -> zgui::render::MemoryReport {
        self.inner.memory()
    }

    fn texture_sink(&mut self) -> &mut dyn zgui::atlas::TextureSink {
        self.inner.texture_sink()
    }

    fn vector_status(&self) -> zgui::render::VectorStatus {
        self.inner.vector_status()
    }

    fn target_pool(&self) -> zgui::render::TargetPoolReport {
        self.inner.target_pool()
    }

    fn release_cached_targets(&mut self) -> u64 {
        self.inner.release_cached_targets()
    }
}

impl Snapshot {
    /// Copies the frame the window just composed out to `path`.
    fn capture(&self, path: &Path) {
        let pixels = self.inner.read_composed();
        match write_png(path, &pixels) {
            Ok(()) => eprintln!(
                "Campy UI snapshot: {} ({}x{})",
                path.display(),
                pixels.size().width,
                pixels.size().height
            ),
            Err(error) => eprintln!("Campy UI snapshot failed for {}: {error}", path.display()),
        }
    }
}

/// Writes a composed frame as an 8-bit RGBA PNG.
fn write_png(path: &Path, pixels: &Pixels) -> Result<(), String> {
    let size = pixels.size();
    let width = size.width.max(0) as u32;
    let height = size.height.max(0) as u32;
    let bytes = pixels.bytes();
    if width == 0 || height == 0 || bytes.len() < (width as usize * height as usize * 4) {
        return Err(format!("an empty {}x{} frame", width, height));
    }
    // The frame is stored with premultiplied alpha; a PNG viewer expects
    // straight alpha, so undo the multiply on the way out (and skip it where
    // alpha is opaque, which is every pixel of a normal window).
    let mut rgba = Vec::with_capacity(bytes.len());
    let bgra = pixels.is_bgra();
    for pixel in bytes.as_chunks::<4>().0 {
        let (r, b) = if bgra {
            (pixel[2], pixel[0])
        } else {
            (pixel[0], pixel[2])
        };
        let alpha = pixel[3] as u32;
        if alpha == 255 || alpha == 0 {
            rgba.extend_from_slice(&[r, pixel[1], b, alpha as u8]);
        } else {
            let unmultiply =
                |channel: u8| ((channel as u32 * 255 + alpha / 2) / alpha).min(255) as u8;
            rgba.extend_from_slice(&[
                unmultiply(r),
                unmultiply(pixel[1]),
                unmultiply(b),
                alpha as u8,
            ]);
        }
    }
    let file = std::fs::File::create(path).map_err(|error| error.to_string())?;
    let mut encoder = png::Encoder::new(std::io::BufWriter::new(file), width, height);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().map_err(|error| error.to_string())?;
    writer
        .write_image_data(&rgba)
        .map_err(|error| error.to_string())?;
    writer.finish().map_err(|error| error.to_string())
}

/// The environment variable naming a point to click, in window CSS pixels:
/// `CAMPY_UI_CLICK=700,450`.
///
/// A click from outside the process is unreliable on this desktop (an
/// injection follows the output under the cursor and carries no focus), and a
/// headless test dispatches into the element tree rather than through the
/// window. So the window clicks itself: the events this sends are the same
/// `SurfaceEvent`s the winit backend sends, in the same order, and everything
/// after them — hit testing, the canvas's capture listeners, the bridge
/// events, the BEAM's selection — is the path a human's click takes.
pub const CLICK_ENV: &str = "CAMPY_UI_CLICK";

/// The environment variable naming a press, a move and a release:
/// `CAMPY_UI_DRAG=x1,y1,x2,y2`. The modifiers come from [`MODS_ENV`].
pub const DRAG_ENV: &str = "CAMPY_UI_DRAG";

/// The environment variable naming the modifiers a probe carries, joined with
/// `+`: `CAMPY_UI_MODS=ctrl`.
pub const MODS_ENV: &str = "CAMPY_UI_MODS";

/// How many moves a probe's drag crosses (`CAMPY_UI_DRAG_STEPS`, default 3).
const STEPS_ENV: &str = "CAMPY_UI_DRAG_STEPS";

/// The interval between a paced drag's moves in milliseconds
/// (`CAMPY_UI_DRAG_INTERVAL_MS`, default 16).
const INTERVAL_ENV: &str = "CAMPY_UI_DRAG_INTERVAL_MS";

/// Asks for a frame at every step too (`CAMPY_UI_DRAG_TICK=1`): the loop then
/// draws continuously, as it would if the platform were pacing it, instead of
/// stop-start on each change.
const TICK_ENV: &str = "CAMPY_UI_DRAG_TICK";

/// How long the window is given to lay out and load before the probe clicks.
const CLICK_DELAY: Duration = Duration::from_millis(3000);

/// A point written `x,y`.
fn point(raw: &str) -> Option<Point<CssPx, Css>> {
    let (x, y) = raw.split_once(',')?;
    Some(Point::new(
        CssPx(x.trim().parse().ok()?),
        CssPx(y.trim().parse().ok()?),
    ))
}

/// The point [`CLICK_ENV`] asks for, if any.
pub fn click_at() -> Option<Point<CssPx, Css>> {
    point(&std::env::var(CLICK_ENV).ok()?)
}

/// The gesture [`DRAG_ENV`] asks for, if any: press at the first point, move
/// to the second and release there.
pub fn drag_at() -> Option<(Point<CssPx, Css>, Point<CssPx, Css>)> {
    let raw = std::env::var(DRAG_ENV).ok()?;
    let parts = raw.split(',').map(str::trim).collect::<Vec<_>>();
    match parts.as_slice() {
        [x1, y1, x2, y2] => Some((point(&format!("{x1},{y1}"))?, point(&format!("{x2},{y2}"))?)),
        _ => None,
    }
}

/// The modifiers [`MODS_ENV`] asks for.
pub fn mods() -> Modifiers {
    let Ok(raw) = std::env::var(MODS_ENV) else {
        return Modifiers::NONE;
    };
    let mut bits = 0u8;
    for part in raw.split('+').map(str::trim) {
        match part {
            "ctrl" | "control" => bits |= Modifiers::CONTROL.bits(),
            "shift" => bits |= Modifiers::SHIFT.bits(),
            "alt" => bits |= Modifiers::ALT.bits(),
            _ => (),
        }
    }
    Modifiers::from_bits_truncate(bits)
}

/// Wraps an application so it presses and releases once, after its first
/// frame, at [`click_at`].
pub struct ClickProbe<A> {
    inner: A,
    /// Press-then-release points: the same point twice is a click.
    gesture: Option<(Point<CssPx, Css>, Point<CssPx, Css>)>,
    modifiers: Modifiers,
    /// How many moves the drag crosses, and how far apart they are.
    steps: u32,
    interval: Duration,
    /// The move the drag has reached (0 has pressed but not moved).
    step: u32,
    due: Option<Instant>,
    surface: Option<zgui::platform::SurfaceId>,
    fired: bool,
}

impl<A: AppHandler> ClickProbe<A> {
    /// Wraps `inner`; does nothing unless [`CLICK_ENV`] is set.
    pub fn new(inner: A) -> Self {
        let gesture = match (click_at(), drag_at()) {
            (Some(at), _) => Some((at, at)),
            (None, drag) => drag,
        };
        let steps = std::env::var(STEPS_ENV)
            .ok()
            .and_then(|raw| raw.trim().parse().ok())
            .unwrap_or(3)
            .clamp(1, 500);
        let interval = Duration::from_millis(
            std::env::var(INTERVAL_ENV)
                .ok()
                .and_then(|raw| raw.trim().parse().ok())
                .unwrap_or(16),
        );
        Self {
            inner,
            gesture,
            modifiers: mods(),
            steps,
            interval,
            step: 0,
            due: None,
            surface: None,
            fired: false,
        }
    }

    /// Sends one pointer event at `at`.
    fn send(
        &mut self,
        cx: &dyn PlatformCx,
        surface: SurfaceId,
        action: PointerAction,
        at: Point<CssPx, Css>,
        button: Option<PointerButton>,
    ) {
        let mut pointer = PointerEvent::mouse(at);
        if let Some(button) = button {
            pointer = pointer.with_button(button);
        }
        self.inner.surface_event(
            cx,
            surface,
            SurfaceEvent::Pointer {
                action,
                event: pointer,
                modifiers: self.modifiers,
                timestamp: cx.clock().timestamp(),
            },
        );
    }

    /// Starts the gesture: a move onto the point, then the press.
    fn press(&mut self, cx: &dyn PlatformCx, surface: SurfaceId, from: Point<CssPx, Css>) {
        trace("probe press");
        eprintln!(
            "campy click probe: {:?} story from {:.0},{:.0} steps={} every {}ms mods ctrl={} shift={}",
            surface,
            from.x.0,
            from.y.0,
            self.steps,
            self.interval.as_millis(),
            self.modifiers.control(),
            self.modifiers.shift()
        );
        self.send(cx, surface, PointerAction::Moved, from, None);
        self.send(
            cx,
            surface,
            PointerAction::Pressed,
            from,
            Some(PointerButton::Primary),
        );
    }

    /// The next point on the path from `from` to `to`.
    fn path(&self, from: Point<CssPx, Css>, to: Point<CssPx, Css>, step: u32) -> Point<CssPx, Css> {
        let fraction = step as f32 / self.steps as f32;
        Point::new(
            CssPx(from.x.0 + (to.x.0 - from.x.0) * fraction),
            CssPx(from.y.0 + (to.y.0 - from.y.0) * fraction),
        )
    }
}

impl<A: AppHandler> AppHandler for ClickProbe<A> {
    fn surfaces_available(&mut self, cx: &dyn PlatformCx) {
        self.inner.surfaces_available(cx);
    }

    fn surfaces_lost(&mut self, cx: &dyn PlatformCx) {
        self.surface = None;
        self.inner.surfaces_lost(cx);
    }

    fn surface_event(
        &mut self,
        cx: &dyn PlatformCx,
        surface: zgui::platform::SurfaceId,
        event: zgui::platform::SurfaceEvent,
    ) {
        if self.gesture.is_some() && !self.fired {
            self.surface = Some(surface);
            // The first frame is the window's own sign that it exists; the
            // press waits a little longer so layout and the initial load have
            // landed.
            if matches!(event, SurfaceEvent::RedrawRequested) && self.due.is_none() {
                self.due = Some(Instant::now() + CLICK_DELAY);
            }
        }
        self.inner.surface_event(cx, surface, event);
    }

    fn wake(&mut self, cx: &dyn PlatformCx, reason: WakeReason) {
        self.inner.wake(cx, reason);
    }

    fn idle(&mut self, cx: &dyn PlatformCx) -> IdlePolicy {
        let policy = self.inner.idle(cx);
        match self.due {
            Some(due) if !self.fired => policy.merge(IdlePolicy::BlockUntil(due)),
            _ => policy,
        }
    }

    fn deadline_reached(&mut self, cx: &dyn PlatformCx) {
        self.inner.deadline_reached(cx);
        if self.fired {
            return;
        }
        let (Some((from, to)), Some(surface), Some(due)) = (self.gesture, self.surface, self.due)
        else {
            return;
        };
        if Instant::now() < due {
            return;
        }
        if self.step == 0 {
            // The first deadline is the layout's grace period: press.
            self.press(cx, surface, from);
        } else if self.step < self.steps {
            trace("probe move");
            // One move per interval: a hand's drag, not a burst, so the frame
            // rate under the gesture is what a user would see.
            self.send(
                cx,
                surface,
                PointerAction::Moved,
                self.path(from, to, self.step),
                None,
            );
        } else {
            trace("probe release");
            self.send(
                cx,
                surface,
                PointerAction::Released,
                to,
                Some(PointerButton::Primary),
            );
            self.fired = true;
            self.due = None;
            return;
        }
        self.step += 1;
        if std::env::var_os(TICK_ENV).is_some() {
            trace("probe tick");
            self.inner
                .surface_event(cx, surface, SurfaceEvent::RedrawRequested);
        }
        let now = Instant::now();
        self.due = Some(now + self.interval);
    }

    fn shutting_down(&mut self, cx: &dyn PlatformCx) {
        self.inner.shutting_down(cx);
    }
}
