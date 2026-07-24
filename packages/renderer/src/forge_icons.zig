//! Forge icon set — custom SVG icons with consistent stroke-based style.
//!
//! These icons use a unified design language: 1.5px stroke, rounded line
//! caps, 16x16 viewBox, currentColor fill. This gives Forge a distinct
//! visual identity separate from Octicons (GitHub) or Material Icons.
//!
//! Usage: same as octicons — pass to renderer.Renderer.drawSvg().
//! Color is applied via the renderer's drawSvg color parameter.

/// Forge logo mark — stylized anvil/hammer hybrid representing "forging" code.
pub const forge_mark: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M2 6h12M4 6v2a2 2 0 0 0 2 2h4a2 2 0 0 0 2-2V6M8 10v4M5 14h6\"/></svg>";

/// File — clean document outline.
pub const file: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3 2h6l4 4v8a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V3a1 1 0 0 1 1-1z\"/><path d=\"M9 2v4h4\"/></svg>";

/// Folder — directory outline.
pub const folder: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M2 4a1 1 0 0 1 1-1h3l2 2h5a1 1 0 0 1 1 1v7a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V4z\"/></svg>";

/// Folder open — expanded directory.
pub const folder_open: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M2 4a1 1 0 0 1 1-1h3l2 2h5a1 1 0 0 1 1 1v1H4l-2 7V4z\"/><path d=\"M3.5 14l1.5-6h10l-1.5 6z\"/></svg>";

/// Search — magnifying glass.
pub const search: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"7\" cy=\"7\" r=\"4.5\"/><path d=\"M10.5 10.5L14 14\"/></svg>";

/// Settings/gear — simplified.
pub const gear: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"8\" cy=\"8\" r=\"2\"/><path d=\"M8 1v2M8 13v2M1 8h2M13 8h2M3.5 3.5l1.4 1.4M11.1 11.1l1.4 1.4M3.5 12.5l1.4-1.4M11.1 4.9l1.4-1.4\"/></svg>";

/// Terminal — command prompt.
pub const terminal: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"2\" y=\"3\" width=\"12\" height=\"10\" rx=\"1\"/><path d=\"M5 7l2 1.5L5 10M9 10h3\"/></svg>";

/// Git branch.
pub const branch: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"4\" cy=\"3\" r=\"1.5\"/><circle cx=\"4\" cy=\"13\" r=\"1.5\"/><circle cx=\"12\" cy=\"6\" r=\"1.5\"/><path d=\"M4 4.5v7M12 7.5c0 3-4 1.5-4 3.5\"/></svg>";

/// Bug — for debug panel.
pub const bug: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"6\" y=\"7\" width=\"4\" height=\"6\" rx=\"2\"/><path d=\"M5 5l1 1M11 5l-1 1M4 9h2M10 9h2M4 12h2M10 12h2M8 4v2\"/></svg>";

/// Sparkle — AI / agent.
pub const sparkle: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 2l1.5 4L13 8l-3.5 2L8 14l-1.5-4L3 8l3.5-2z\"/></svg>";

/// Send — message send.
pub const send: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M2 8l12-5-5 12-2-5-5-2z\"/></svg>";

/// Plus — add.
pub const plus: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 3v10M3 8h10\"/></svg>";

/// Chevron down.
pub const chevron_down: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M4 6l4 4 4-4\"/></svg>";

/// Chevron right.
pub const chevron_right: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M6 4l4 4-4 4\"/></svg>";

/// Check — success/done.
pub const check: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3 8l3 3 7-7\"/></svg>";

/// Close X.
pub const close: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M4 4l8 8M12 4l-8 8\"/></svg>";

/// Copy.
pub const copy: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"5\" y=\"5\" width=\"9\" height=\"9\" rx=\"1\"/><path d=\"M11 5V3a1 1 0 0 0-1-1H3a1 1 0 0 0-1 1v7a1 1 0 0 0 1 1h2\"/></svg>";

/// Sync/refresh.
pub const sync: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M13 8a5 5 0 0 1-9 3M3 8a5 5 0 0 1 9-3M13 2v3h-3M3 14v-3h3\"/></svg>";

/// Paperclip — attachment.
pub const paperclip: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M14 7l-6 6a3.5 3.5 0 0 1-5-5l6-6a2.5 2.5 0 0 1 3.5 3.5l-6 6a1.5 1.5 0 0 1-2-2l5-5\"/></svg>";

/// Extensions — puzzle piece.
pub const extensions: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M6 2h4v2a1.5 1.5 0 0 0 3 0V2h1v4h-2a1.5 1.5 0 0 0 0 3h2v5h-4v-2a1.5 1.5 0 0 0-3 0v2H2v-4h2a1.5 1.5 0 0 0 0-3H2V2h4z\"/></svg>";

/// Warning triangle.
pub const warning: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 2l6 11H2L8 2z\"/><path d=\"M8 7v3M8 12v.5\"/></svg>";

/// Error circle.
pub const error_icon: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"8\" cy=\"8\" r=\"6\"/><path d=\"M8 5v3M8 11v.5\"/></svg>";

/// Info circle.
pub const info_icon: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"8\" cy=\"8\" r=\"6\"/><path d=\"M8 7v3M8 5v.5\"/></svg>";

/// Play — run task.
pub const play: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M4 3l9 5-9 5V3z\"/></svg>";

/// Stop — cancel task.
pub const stop: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"4\" y=\"4\" width=\"8\" height=\"8\" rx=\"1\"/></svg>";

/// Repo — git repository.
pub const repo: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3 2h8a1 1 0 0 1 1 1v11l-2-1-2 1-2-1-2 1V3a1 1 0 0 0-1-1z\"/><path d=\"M3 2a1 1 0 0 0-1 1v11l2-1\"/></svg>";

/// Kebab menu (horizontal dots).
pub const kebab: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"currentColor\"><circle cx=\"3\" cy=\"8\" r=\"1.2\"/><circle cx=\"8\" cy=\"8\" r=\"1.2\"/><circle cx=\"13\" cy=\"8\" r=\"1.2\"/></svg>";

/// Dash — minus.
pub const dash: [:0]const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3 8h10\"/></svg>";
