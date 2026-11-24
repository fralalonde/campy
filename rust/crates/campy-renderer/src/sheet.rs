//! The campy application stylesheet.
//!
//! One static sheet for the whole application. Themes are root classes
//! that flip custom properties; zgui-ui components bring their own sheets
//! and inherit the cascade.

use zgui::prelude::*;

/// Base layout vocabulary: absolute (Free) and box (Column/Row) layout,
/// plus the theme custom properties the BEAM can flip with a root class.
pub const CAMPY_SHEET: &str = css!(
    ":root { --campy-bg: #f4f4f5; --campy-panel: #ffffff; --campy-text: #18181b;
              --campy-accent: #356df3; --campy-border: #d4d4d8; }
     .campy-dark { --campy-bg: #18181b; --campy-panel: #27272a; --campy-text: #f4f4f5;
                   --campy-accent: #60a5fa; --campy-border: #3f3f46; }
     .campy-root { width: 100%; height: 100%; background: var(--campy-bg);
                   color: var(--campy-text); font-size: 14px; }
     .campy-free { position: relative; }
     .campy-free > .campy-control { position: absolute; }
     .campy-col { display: flex; flex-direction: column; gap: 8px; }
     .campy-row { display: flex; flex-direction: row; gap: 8px; }
     .campy-control { min-width: 0; min-height: 0; }
     .campy-widget-button { padding: 6px 14px; border-radius: 6px;
                             background: var(--campy-accent); color: #ffffff;
                             border: 1px solid color-mix(in srgb, var(--campy-accent) 70%, #000);
                             font-weight: 500; }
     .campy-widget-button:hover { filter: brightness(1.08); }
     .campy-widget-button:active { filter: brightness(0.94); }
     .campy-check-row { align-items: center; gap: 8px; }
     .campy-list-row { padding: 3px 8px; }
     .campy-console { padding: 6px 10px; white-space: pre-wrap;
                      font-family: 'JetBrains Mono', monospace; font-size: 13px;
                      overflow: auto; }
     .campy-editor { font-family: 'JetBrains Mono', monospace; }
     .campy-surface { position: relative; background: var(--campy-panel);
                      overflow: hidden; }
     .campy-surface-grid { position: absolute; inset: 0;
                            background-image:
                              linear-gradient(var(--campy-border) 1px, transparent 1px),
                              linear-gradient(90deg, var(--campy-border) 1px, transparent 1px);
                            background-size: 8px 8px; opacity: 0.35; pointer-events: none; }
     .campy-selected { outline: 1px solid var(--campy-accent); outline-offset: 1px; }
     .campy-marquee { position: absolute; border: 1px solid var(--campy-accent);
                       background: color-mix(in srgb, var(--campy-accent) 12%, transparent);
                       pointer-events: none; }"
);
