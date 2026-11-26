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
    ":root { --campy-grid: #e4e6ec;
              --campy-bg: #f1f2f5; --campy-panel: #ffffff; --campy-raised: #f6f7f9;
              --campy-hover: #e9ebf0; --campy-text: #1b1d23; --campy-muted: #6b7280;
              --campy-border: #d8dbe2; --campy-accent: #356df3; --campy-accent-soft: #e3ebff;
              --campy-ok: #2f8a55; --campy-danger: #b4454f; }",
    // zgui-ui, the terminal and the editor each carry their own custom
    // properties. Flipping only our own tokens leaves those controls in the
    // theme they were written for (a dark console in a light window), so each
    // theme sets theirs too — the app's theme is the one theme.
    ".campy-dark {
        --zui-color-background: #17191e; --zui-color-foreground: #e6e8ee;
        --zui-color-card: #17191e; --zui-color-popover: #1e2128;
        --zui-color-primary: #5b8cff; --zui-color-primary-foreground: #ffffff;
        --zui-color-secondary: #262a33; --zui-color-secondary-foreground: #e6e8ee;
        --zui-color-muted: #1e2128; --zui-color-muted-foreground: #8b93a3;
        --zui-color-accent: #22304d; --zui-color-accent-foreground: #e6e8ee;
        --zui-color-border: #282c35; --zui-color-input: #282c35;
        --zui-color-ring: #5b8cff; --zui-color-destructive: #c05a64;
        --terminal-background: #101114; --terminal-selection: #22304d;
        --terminal-cursor: #5b8cff; --terminal-cursor-text: #101114;
        --terminal-black: #101114; --terminal-bright-black: #8b93a3;
        --terminal-white: #e6e8ee; --terminal-bright-white: #ffffff;
        --terminal-red: #e06c75; --terminal-bright-red: #ef7c86;
        --terminal-green: #98c379; --terminal-bright-green: #a9d18a;
        --terminal-yellow: #e5c07b; --terminal-bright-yellow: #f0cf8e;
        --terminal-blue: #61afef; --terminal-bright-blue: #7cc0ff;
        --terminal-magenta: #c678dd; --terminal-bright-magenta: #d795e8;
        --terminal-cyan: #56b6c2; --terminal-bright-cyan: #6fd0dc;
        --editor-current-line: #1e2128; --editor-selection: #22304d;
        --editor-cursor: #5b8cff; --editor-cursor-text: #101114;
        --editor-gutter-fg: #6b7280; --editor-gutter-current-fg: #e6e8ee;
        --editor-scrollbar-thumb: #3a3f4b;
        --syntax-comment: #7f8b99; --syntax-keyword: #7aa2f7;
        --syntax-string: #9ece6a; --syntax-number: #e5c07b;
        --syntax-type: #2ac3de; --syntax-function: #7dcfff;
        --syntax-variable: #e6e8ee; --syntax-constant: #ff9e64;
        --syntax-operator: #89ddff; --syntax-punctuation: #8b93a3;
        --syntax-property: #73daca; --syntax-attribute: #bb9af7;
     }
     .campy-light {
        --zui-color-background: #ffffff; --zui-color-foreground: #1b1d23;
        --zui-color-card: #ffffff; --zui-color-popover: #ffffff;
        --zui-color-primary: #356df3; --zui-color-primary-foreground: #ffffff;
        --zui-color-secondary: #eceef3; --zui-color-secondary-foreground: #1b1d23;
        --zui-color-muted: #f6f7f9; --zui-color-muted-foreground: #6b7280;
        --zui-color-accent: #e3ebff; --zui-color-accent-foreground: #1b1d23;
        --zui-color-border: #d8dbe2; --zui-color-input: #d8dbe2;
        --zui-color-ring: #356df3; --zui-color-destructive: #b4454f;
        --terminal-background: #ffffff; --terminal-selection: #e3ebff;
        --terminal-cursor: #356df3; --terminal-cursor-text: #ffffff;
        --terminal-black: #1b1d23; --terminal-bright-black: #6b7280;
        --terminal-white: #f6f7f9; --terminal-bright-white: #ffffff;
        --terminal-red: #b4454f; --terminal-bright-red: #cf5a64;
        --terminal-green: #2f8a55; --terminal-bright-green: #3da868;
        --terminal-yellow: #a16207; --terminal-bright-yellow: #c07d10;
        --terminal-blue: #356df3; --terminal-bright-blue: #4d80ff;
        --terminal-magenta: #9d4edd; --terminal-bright-magenta: #b06ef0;
        --terminal-cyan: #1f7f8c; --terminal-bright-cyan: #2a99a8;
        --editor-current-line: #f2f4f8; --editor-selection: #e3ebff;
        --editor-cursor: #356df3; --editor-cursor-text: #ffffff;
        --editor-gutter-fg: #9aa1ad; --editor-gutter-current-fg: #1b1d23;
        --editor-scrollbar-thumb: #c9cdd6;
        --syntax-comment: #6b7280; --syntax-keyword: #7c3aed;
        --syntax-string: #2f8a55; --syntax-number: #a16207;
        --syntax-type: #0e7490; --syntax-function: #1d4ed8;
        --syntax-variable: #1b1d23; --syntax-constant: #b45309;
        --syntax-operator: #0e7490; --syntax-punctuation: #6b7280;
        --syntax-property: #0f766e; --syntax-attribute: #9d4edd;
     }
     /* Solarized, from the palette's own bases: base03 for the page, base02
        for panels, base0 for text, and its published accents. */
     .campy-solarized {
        --campy-grid: #0b3f4c;
        --campy-bg: #002b36; --campy-panel: #073642; --campy-raised: #0b3f4c;
        --campy-hover: #12495a; --campy-text: #93a1a1; --campy-muted: #657b83;
        --campy-border: #0f4a5a; --campy-accent: #268bd2;
        --campy-accent-soft: #0b3d52; --campy-ok: #859900; --campy-danger: #dc322f;
        --zui-color-background: #073642; --zui-color-foreground: #93a1a1;
        --zui-color-card: #073642; --zui-color-popover: #0b3f4c;
        --zui-color-primary: #268bd2; --zui-color-primary-foreground: #fdf6e3;
        --zui-color-secondary: #0b3f4c; --zui-color-secondary-foreground: #93a1a1;
        --zui-color-muted: #002b36; --zui-color-muted-foreground: #657b83;
        --zui-color-accent: #0b3d52; --zui-color-accent-foreground: #93a1a1;
        --zui-color-border: #0f4a5a; --zui-color-input: #0f4a5a;
        --zui-color-ring: #268bd2; --zui-color-destructive: #dc322f;
        --terminal-background: #002b36; --terminal-selection: #0b3d52;
        --terminal-cursor: #268bd2; --terminal-cursor-text: #002b36;
        --terminal-black: #073642; --terminal-bright-black: #586e75;
        --terminal-white: #eee8d5; --terminal-bright-white: #fdf6e3;
        --terminal-red: #dc322f; --terminal-bright-red: #cb4b16;
        --terminal-green: #859900; --terminal-bright-green: #93a1a1;
        --terminal-yellow: #b58900; --terminal-bright-yellow: #657b83;
        --terminal-blue: #268bd2; --terminal-bright-blue: #839496;
        --terminal-magenta: #d33682; --terminal-bright-magenta: #6c71c4;
        --terminal-cyan: #2aa198; --terminal-bright-cyan: #93a1a1;
        --editor-current-line: #0b3f4c; --editor-selection: #0b3d52;
        --editor-cursor: #268bd2; --editor-cursor-text: #002b36;
        --editor-gutter-fg: #586e75; --editor-gutter-current-fg: #93a1a1;
        --editor-scrollbar-thumb: #12495a;
        --syntax-comment: #586e75; --syntax-keyword: #859900;
        --syntax-string: #2aa198; --syntax-number: #d33682;
        --syntax-type: #b58900; --syntax-function: #268bd2;
        --syntax-variable: #93a1a1; --syntax-constant: #cb4b16;
        --syntax-operator: #859900; --syntax-punctuation: #839496;
        --syntax-property: #268bd2; --syntax-attribute: #6c71c4;
     }
     /* The form editor's designed controls are passive: the pointer goes
        through them to the canvas, which handles every event. */
     .campy-passive { pointer-events: none; }
     .campy-check-glyph { min-width: 16px; color: var(--campy-muted); }
     .campy-dark { --campy-grid: #23262e;
                   --campy-bg: #101114; --campy-panel: #17191e; --campy-raised: #1e2128;
                   --campy-hover: #262a33; --campy-text: #e6e8ee; --campy-muted: #8b93a3;
                   --campy-border: #282c35; --campy-accent: #5b8cff;
                   --campy-accent-soft: #22304d; --campy-ok: #3f9d63;
                   --campy-danger: #c05a64; }",
    // --- document -----------------------------------------------------------
    ".campy-root { width: 100%; height: 100%; background: var(--campy-bg);
                   color: var(--campy-text); font-size: 13px;
                   font-family: 'Cantarell', 'Noto Sans', sans-serif; }",
    ".campy-control { min-width: 0; min-height: 0; box-sizing: border-box; }",
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
    ".campy-widget-button { box-sizing: border-box;
                            display: flex; align-items: center; justify-content: center;
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
                                                border-color: transparent; font-size: 22px;
                                                color: var(--campy-muted); }",
    ".campy-palette-tile .campy-widget-button:hover { background: var(--campy-hover);
                                                      color: var(--campy-text); }",
    // Run / Stop carry the only saturated colours in the bar.
    ".campy-run .campy-widget-button { background: var(--campy-ok); color: #ffffff;
                                       border-color: transparent; }",
    ".campy-stop .campy-widget-button { background: var(--campy-danger); color: #ffffff;
                                        border-color: transparent; }",
    // Run buttons sit inside navigator rows: small, and not a full-height
    // control that would push the row around.
    ".campy-nav-run .campy-widget-button { min-height: 0; padding: 0; font-size: 10px;
                                          line-height: 1; border-radius: 4px;
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
    ".campy-choice { padding: 0 12px; }",
    ".campy-choice-line { display: flex; align-items: center;
                          justify-content: space-between; width: 100%; }",
    ".campy-choice-mark { color: var(--campy-muted); font-size: 11px; margin-left: 6px; }",
    ".campy-choice-popup { position: absolute; background: var(--campy-panel);
                           border: 1px solid var(--campy-border); border-radius: 8px;
                           padding: 4px; }",
    ".campy-choice-entry { width: 100%; height: 26px; display: flex; align-items: center;
                           border-radius: 5px; color: var(--campy-text); font-size: 13px; }",
    ".campy-choice-row-line { display: flex; justify-content: flex-start;
                              align-items: center; width: 100%; }",
    ".campy-choice-entry:hover { background: var(--campy-hover); }",
    ".campy-choice-on { background: var(--campy-accent-soft); }",
    ".campy-choice-tick { width: 16px; color: var(--campy-accent); }",
    ".campy-dialog-primary .campy-widget-button { background: var(--campy-accent);
                                                  border-color: transparent;
                                                  color: #ffffff; }",
    ".campy-console-clear .campy-widget-button { background: transparent;
                                                 border-color: var(--campy-border); }",
    ".campy-project-icon-action .campy-widget-button { background: transparent;
                                                       border-color: var(--campy-border); }",
    // --- lists --------------------------------------------------------------
    // A list is a scroll port: its rows live inside the control's rectangle.
    // The port's own block box otherwise grows to its content and paints the
    // rows straight out of the dialog (or the navigator) and across the window.
    ".campy-list { overflow: hidden; }",
    ".campy-list .zui-virtual-list { height: 100%; width: 100%; }",
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
    ".campy-tab-x .campy-widget-button { background: transparent; border-color: transparent;
                                        color: var(--campy-muted); font-size: 14px;
                                        padding: 0; min-height: 0; border-radius: 4px; }",
    ".campy-tab-x .campy-widget-button:hover { background: var(--campy-hover);
                                              color: var(--campy-text); }",
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
    ".campy-surface-grid { position: absolute; left: 0; top: 0; width: 100%; height: 100%;
                           background-image:
                             linear-gradient(to right, var(--campy-grid) 1px, transparent 1px),
                             linear-gradient(to bottom, var(--campy-grid) 1px, transparent 1px);
                           background-size: 8px 8px; background-repeat: repeat;
                           pointer-events: none; }",
    ".campy-selected { outline: 2px solid var(--campy-accent); outline-offset: 1px; }",
    ".campy-member { outline: 1px solid var(--campy-accent); outline-offset: 0px;
                     background: transparent; }",
    // Non-visual components in the designer: a pictogram tile with the
    // component's name under it, so a timer reads as a thing, not a blank.
    ".campy-nonvisual { display: flex; flex-direction: column; align-items: center;
                        justify-content: center; gap: 4px; padding: 6px;
                        border: 1px dashed var(--campy-accent);
                        border-radius: 8px; background: var(--campy-accent-soft); }",
    ".campy-nonvisual-glyph-box { display: flex; align-items: center; justify-content: center;
                                  width: 46px; height: 46px; border-radius: 8px;
                                  background: var(--campy-panel);
                                  border: 1px solid var(--campy-accent); }",
    ".campy-nonvisual-glyph { font-size: 26px; color: var(--campy-accent); }",
    ".campy-nonvisual-name { font-size: 11px; color: var(--campy-text); }",
    ".campy-grip { background: var(--campy-panel);
                  border: 1px solid var(--campy-accent); border-radius: 2px; }",
    ".campy-grip-window { background: var(--campy-raised);
                          border-color: var(--campy-border); }",
    ".campy-tooltip { position: absolute; background: var(--campy-raised);
                      border: 1px solid var(--campy-border); border-radius: 6px;
                      padding: 4px 8px; font-size: 12px; color: var(--campy-text);
                      pointer-events: none; }",
    // Where a drag would drop: the prospective parent, outlined while the
    // pointer is still down.
    ".campy-drop { border: 2px dashed var(--campy-accent); background: transparent;
                   pointer-events: none; }",
    // The selection frame is a rubber band, not a veil: the components it
    // would take are outlined behind it, and must stay readable through it.
    ".campy-marquee { border: 1px solid var(--campy-accent);
                      background: transparent; pointer-events: none; }",
    // --- inspector ----------------------------------------------------------
    ".campy-insp-label { color: var(--campy-muted); font-size: 12px; }",
    ".campy-insp-selection { font-weight: 600; }",
    ".campy-insp-text { background: var(--campy-raised);
                        border: 1px solid var(--campy-border); border-radius: 5px; }",
    ".campy-insp-text:hover { border-color: var(--campy-muted); }",
    ".campy-control > .campy-check-row { width: 100%; height: 100%; }
     .campy-insp-bool .campy-check-row { justify-content: flex-start; padding: 0 8px;
                                        background: var(--campy-raised);
                                        border: 1px solid var(--campy-border);
                                        border-radius: 5px; }",
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
                         border: 1px solid var(--campy-border); border-radius: 5px; }",
    // --- console and editor -------------------------------------------------
    ".campy-console { padding: 4px 10px; font-family: 'Adwaita Mono',
                      'Iosevka Nerd Font', monospace; font-size: 12px;
                      background: var(--terminal-background);
                      color: var(--campy-text); overflow: auto; }",
    ".campy-console-title { font-weight: 600; }",
    ".campy-console-state { color: var(--campy-muted); font-size: 12px; }",
    ".campy-editor { font-family: 'Adwaita Mono', 'Iosevka Nerd Font', monospace; }",
    ".campy-code-title { color: var(--campy-muted); font-size: 12px; }",
    ".campy-code-handler { color: var(--campy-text); font-size: 12px; }",
    // --- widgets ------------------------------------------------------------
    ".campy-check-row { align-items: center; gap: 8px; }",
    ".campy-picture { width: 100%; height: 100%; }",
    // --- dialogs ------------------------------------------------------------
    // The file dialog's backdrop: dims the window and swallows presses so a
    // click behind the dialog cannot reach the canvas.
    ".campy-backdrop { background: rgba(0, 0, 0, 0.45); }",
    ".campy-dialog { background: var(--campy-panel); border: 1px solid var(--campy-border);
                     border-radius: 10px; }",
    ".campy-dialog-title { font-size: 16px; font-weight: 600; }",
    ".campy-dialog-label { color: var(--campy-muted); }",
    ".campy-dialog-text { color: var(--campy-muted); font-size: 12px; }",
    ".campy-dialog-check { align-items: center; gap: 8px; }",
    ".campy-context-menu, .campy-completions { background: var(--campy-panel);
                     border: 1px solid var(--campy-border); border-radius: 8px; }"
);
