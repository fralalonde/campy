//! The campy application stylesheet.
//!
//! One static sheet for the whole application. Themes are root classes that
//! flip custom properties; zgui-ui components bring their own sheets and
//! inherit the cascade.
//!
//! The shell emitter tags every control it describes with a `class` prop
//! (`campy-nav`, `campy-insp-label`, …) and the renderer applies those to the
//! control's wrapper, so the whole chrome is addressable from here. The
//! wrappers are absolutely positioned inside their parents (the shell is a
//! hand-placed 1280×860 layout); only the design canvas and designed forms
//! switch to flow layout, and they carry their own `layout` class.

use zgui::prelude::*;

/// The application sheet: theme tokens, chrome layout, and the widget styles
/// for every class the shell emits.
pub const CAMPY_SHEET: &str = css!(
    // --- theme tokens -------------------------------------------------------
    ":root { --campy-bg: #f1f2f5; --campy-panel: #ffffff; --campy-raised: #f6f7f9;
              --campy-hover: #e9ebf0; --campy-text: #1b1d23; --campy-muted: #6b7280;
              --campy-border: #d8dbe2; --campy-accent: #356df3; --campy-accent-soft: #e3ebff;
              --campy-ok: #2f8a55; --campy-danger: #b4454f; }",
    ".campy-dark { --campy-bg: #101114; --campy-panel: #17191e; --campy-raised: #1e2128;
                   --campy-hover: #262a33; --campy-text: #e6e8ee; --campy-muted: #8b93a3;
                   --campy-border: #282c35; --campy-accent: #5b8cff;
                   --campy-accent-soft: #22304d; --campy-ok: #3f9d63;
                   --campy-danger: #c05a64; }",
    // --- document -----------------------------------------------------------
    ".campy-root { width: 100%; height: 100%; background: var(--campy-bg);
                   color: var(--campy-text); font-size: 13px;
                   font-family: 'Cantarell', 'Noto Sans', sans-serif; }",
    ".campy-control { min-width: 0; min-height: 0; }",
    ".campy-free { position: relative; }",
    ".campy-free > .campy-control { position: absolute; }",
    ".campy-col { display: flex; flex-direction: column; gap: 8px; }",
    ".campy-row { display: flex; flex-direction: row; gap: 8px; align-items: center; }",
    ".campy-rule { background: var(--campy-border); }",
    ".campy-disabled { opacity: 0.42; }",
    // --- chrome regions -----------------------------------------------------
    ".campy-host { width: 100%; height: 100%; }
     .campy-ide-root { background: var(--campy-bg); }",
    ".campy-menubar { background: var(--campy-panel);
                      border-bottom: 1px solid var(--campy-border); }",
    ".campy-nav { background: var(--campy-panel);
                  border-right: 1px solid var(--campy-border); }",
    ".campy-inspector-pane { background: var(--campy-panel);
                             border-left: 1px solid var(--campy-border); }",
    ".campy-inspector, .campy-project-panel { background: var(--campy-panel); }",
    ".campy-canvas { background: var(--campy-bg); }",
    ".campy-console-pane { background: var(--campy-panel);
                           border-top: 1px solid var(--campy-border); }",
    ".campy-status-bar { background: var(--campy-panel);
                         border-top: 1px solid var(--campy-border); }",
    // --- typography ---------------------------------------------------------
    ".campy-title { font-size: 11px; font-weight: 600; letter-spacing: 0.08em;
                    color: var(--campy-muted); }",
    ".campy-status { color: var(--campy-muted); font-size: 12px; }",
    ".campy-status-path { color: var(--campy-muted); font-size: 12px; }",
    // --- buttons ------------------------------------------------------------
    ".campy-control > .campy-widget-button { width: 100%; height: 100%; }",
    ".campy-widget-button { display: flex; align-items: center; justify-content: center;
                            padding: 0 10px; border-radius: 6px;
                            background: var(--campy-raised); color: var(--campy-text);
                            border: 1px solid var(--campy-border); font-size: 13px; }",
    ".campy-widget-button:hover { background: var(--campy-hover); }",
    ".campy-widget-button:active { background: var(--campy-accent-soft);
                                  border-color: var(--campy-accent); }",
    // Menus sit in the menu bar and read as text, not as buttons.
    ".campy-menubar .campy-widget-button { background: transparent;
                                          border-color: transparent; padding: 0 12px;
                                          font-weight: 500; }",
    ".campy-menubar .campy-widget-button:hover { background: var(--campy-hover); }",
    ".campy-menu-row .campy-widget-button { justify-content: flex-start;
                                            background: transparent;
                                            border-color: transparent;
                                            border-radius: 4px; padding: 0 8px; }",
    // Palette tiles: quiet squares that light up under the pointer.
    ".campy-palette { background: transparent; }",
    ".campy-palette-tile .campy-widget-button { background: transparent;
                                                border-color: transparent; font-size: 16px;
                                                color: var(--campy-muted); }",
    ".campy-palette-tile .campy-widget-button:hover { background: var(--campy-hover);
                                                      color: var(--campy-text); }",
    // Run / Stop carry the only saturated colours in the bar.
    ".campy-run .campy-widget-button { background: var(--campy-ok); color: #ffffff;
                                       border-color: transparent; }",
    ".campy-stop .campy-widget-button { background: var(--campy-danger); color: #ffffff;
                                        border-color: transparent; }",
    // Icon-sized affordances.
    ".campy-icon-button .campy-widget-button { background: transparent;
                                               border-color: transparent;
                                               color: var(--campy-muted); padding: 0; }",
    ".campy-icon-button .campy-widget-button:hover { background: var(--campy-hover);
                                                     color: var(--campy-text); }",
    ".campy-view-toggle .campy-widget-button { padding: 0; font-size: 15px;
                                               background: var(--campy-raised); }",
    ".campy-tab-button .campy-widget-button { background: transparent;
                                              border-color: transparent;
                                              color: var(--campy-muted); }",
    ".campy-tab-button .campy-widget-button:hover { color: var(--campy-text); }",
    ".campy-insp-tab .campy-widget-button { background: transparent;
                                            border-color: transparent;
                                            color: var(--campy-muted); font-weight: 500; }",
    ".campy-insp-tab .campy-widget-button:hover { color: var(--campy-text);
                                                  background: var(--campy-hover); }",
    ".campy-tab-on .campy-widget-button { color: var(--campy-text);
                                           background: var(--campy-hover);
                                           border-color: var(--campy-border); }",
    ".campy-cycle { justify-content: space-between; font-size: 12px; }",
    ".campy-dialog-primary .campy-widget-button { background: var(--campy-accent);
                                                  border-color: transparent;
                                                  color: #ffffff; }",
    ".campy-console-clear .campy-widget-button { background: transparent;
                                                 border-color: var(--campy-border); }",
    ".campy-project-icon-action .campy-widget-button { background: transparent;
                                                       border-color: var(--campy-border); }",
    // --- lists --------------------------------------------------------------
    ".campy-list-row { display: flex; align-items: center; padding: 0 10px; height: 100%;
                       color: var(--campy-muted); border-radius: 5px; font-size: 13px; }",
    ".campy-list-row:hover { background: var(--campy-hover); color: var(--campy-text); }",
    ".campy-list-active { background: var(--campy-accent-soft); color: var(--campy-text);
                          font-weight: 600; }",
    ".campy-option { display: flex; align-items: center; padding: 0 10px; }",
    // --- menu popup ---------------------------------------------------------
    ".campy-menu-popup { position: absolute; background: var(--campy-panel);
                         border: 1px solid var(--campy-border); border-radius: 8px;
                         padding: 4px; }",
    ".campy-menu-item { display: flex; align-items: center; width: 100%; height: 26px;
                        padding: 0 10px; border-radius: 5px; font-size: 13px;
                        color: var(--campy-text); }",
    ".campy-menu-item:hover { background: var(--campy-accent-soft); }",
    ".campy-menu-line { display: flex; justify-content: space-between;
                        align-items: center; width: 100%; }",
    ".campy-menu-shortcut { color: var(--campy-muted); font-size: 12px; }",
    ".campy-menu-on { background: var(--campy-hover); }",
    ".campy-menu-separator { height: 1px; margin: 4px 6px; background: var(--campy-border); }",
    ".campy-menu-trigger { font-weight: 500; }",
    // --- module tabs --------------------------------------------------------
    ".campy-tab-strip { background: var(--campy-panel);
                        border-bottom: 1px solid var(--campy-border); }",
    ".campy-module-tab .campy-widget-button { justify-content: flex-start; padding: 0 12px;
                                              background: transparent;
                                              border-color: transparent; color: var(--campy-muted);
                                              border-radius: 6px 6px 0 0; font-size: 12px; }",
    ".campy-module-tab .campy-widget-button:hover { background: var(--campy-hover);
                                                    color: var(--campy-text); }",
    ".campy-module-tab.campy-tab-on .campy-widget-button { background: var(--campy-bg);
                                                           color: var(--campy-text);
                                                           border-color: var(--campy-border);
                                                           border-bottom-color: var(--campy-bg); }",
    // --- canvas -------------------------------------------------------------
    ".campy-canvas-title { background: var(--campy-raised);
                           border: 1px solid var(--campy-border); border-bottom: none;
                           border-radius: 6px 6px 0 0; padding: 0 10px;
                           font-weight: 600; color: var(--campy-text); }",
    ".campy-canvas-form { background: var(--campy-panel);
                          border: 1px solid var(--campy-border);
                          border-radius: 0 6px 6px 6px; }",
    ".campy-surface { position: relative; overflow: hidden; }",
    ".campy-selected { outline: 2px solid var(--campy-accent); outline-offset: 1px; }",
    ".campy-marquee { border: 1px solid var(--campy-accent);
                      background: var(--campy-accent-soft); pointer-events: none; }",
    // --- inspector ----------------------------------------------------------
    ".campy-insp-label { color: var(--campy-muted); font-size: 12px; }",
    ".campy-insp-selection { font-weight: 600; }",
    ".campy-insp-text { background: var(--campy-raised);
                        border: 1px solid var(--campy-border); border-radius: 5px;
                        padding: 0 8px; }",
    ".campy-insp-text:hover { border-color: var(--campy-muted); }",
    ".campy-insp-open .campy-widget-button { justify-content: flex-start;
                                             background: transparent;
                                             border-color: var(--campy-border);
                                             color: var(--campy-text); }",
    ".campy-insp-event .campy-widget-button { justify-content: flex-start;
                                              background: transparent;
                                              border-color: var(--campy-border);
                                              color: var(--campy-text); }",
    ".campy-field-label { color: var(--campy-muted); font-size: 12px; }",
    ".campy-field-text { color: var(--campy-muted); }",
    ".campy-field-edit { background: var(--campy-raised);
                         border: 1px solid var(--campy-border); border-radius: 5px;
                         padding: 0 8px; }",
    // --- console and editor -------------------------------------------------
    ".campy-console { padding: 4px 10px; font-family: 'Adwaita Mono',
                      'Iosevka Nerd Font', monospace; font-size: 12px;
                      background: var(--campy-bg); color: var(--campy-text);
                      overflow: auto; }",
    ".campy-console-title { font-weight: 600; }",
    ".campy-console-state { color: var(--campy-muted); font-size: 12px; }",
    ".campy-editor { font-family: 'Adwaita Mono', 'Iosevka Nerd Font', monospace; }",
    ".campy-code-title { color: var(--campy-muted); font-size: 12px; }",
    ".campy-code-handler { color: var(--campy-text); font-size: 12px; }",
    // --- widgets ------------------------------------------------------------
    ".campy-check-row { align-items: center; gap: 8px; }",
    ".campy-picture { width: 100%; height: 100%; }",
    // --- dialogs ------------------------------------------------------------
    ".campy-dialog { background: var(--campy-panel); border: 1px solid var(--campy-border);
                     border-radius: 10px; }",
    ".campy-dialog-title { font-size: 16px; font-weight: 600; }",
    ".campy-dialog-label { color: var(--campy-muted); }",
    ".campy-dialog-text { color: var(--campy-muted); font-size: 12px; }",
    ".campy-dialog-check { align-items: center; gap: 8px; }",
    ".campy-context-menu, .campy-completions { background: var(--campy-panel);
                     border: 1px solid var(--campy-border); border-radius: 8px; }"
);
