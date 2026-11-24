//! Debug screenshots of the live window.
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
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

use zgui::bits::DamageSet;
use zgui::render::{RenderTarget, Renderer};
use zgui_render_wgpu::{GroupPrecision, Pixels, PresentPacing, SharedGraphics};

/// The environment variable naming the PNG to write.
pub const ENV: &str = "CAMPY_UI_SNAPSHOT";
/// How long a window may settle before its frame is taken.
const DELAY_ENV: &str = "CAMPY_UI_SNAPSHOT_DELAY_MS";
const DEFAULT_DELAY: Duration = Duration::from_millis(2500);

/// The requested screenshot path, if screenshots are on.
pub fn path() -> Option<PathBuf> {
    std::env::var_os(ENV).map(PathBuf::from)
}

fn delay() -> Duration {
    std::env::var(DELAY_ENV)
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .map(Duration::from_millis)
        .unwrap_or(DEFAULT_DELAY)
}

/// The renderer factory a snapshotting application's windows are drawn
/// through. Mirrors zgui's own factory (`zgui::app::graphics`) so that the
/// frame drawn here is the frame a normal run would draw, then reads it back.
pub fn factory(path: PathBuf) -> zgui::runtime::RendererFactory {
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
        let pacing = match surface.present_pacing() {
            zgui::platform::PresentPacing::Platform => PresentPacing::Platform,
            _ => PresentPacing::Display,
        };
        let mut renderer = graphics
            .renderer_for_surface(target, handles, pacing, None)
            .map_err(zgui::runtime::AppError::GpuUnavailable)?;
        if pacing == PresentPacing::Platform {
            let gate = Arc::clone(surface);
            renderer.set_present_gate(Box::new(move || gate.present_now()));
        }
        renderer.set_crops_buffers(surface.crops_buffers());
        renderer.set_group_precision(precision);
        zgui_render_vector_vello::attach(&mut renderer, target.size);
        let index = opened.fetch_add(1, Ordering::Relaxed);
        Ok(Box::new(Snapshot {
            inner: renderer,
            path: numbered(&path, index),
            due: Instant::now() + delay(),
            taken: false,
        }))
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
    inner: zgui_render_wgpu::WgpuRenderer,
    path: PathBuf,
    due: Instant,
    taken: bool,
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
            let pixels = self.inner.read_composed();
            match write_png(&self.path, &pixels) {
                Ok(()) => eprintln!(
                    "Campy UI snapshot: {} ({}x{})",
                    self.path.display(),
                    pixels.size().width,
                    pixels.size().height
                ),
                Err(error) => eprintln!(
                    "Campy UI snapshot failed for {}: {error}",
                    self.path.display()
                ),
            }
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
    for pixel in bytes.chunks_exact(4) {
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
