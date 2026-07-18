#ifndef MAC_WINDOW_H
#define MAC_WINDOW_H

#include <stdbool.h>
#include <stddef.h>

// ForgeTextSpan and the callback typedefs (ForgeRenderCallback,
// ForgeKeyCallback, ForgeMouseCallback) are defined in shared/backend.h.
// We include it here so consumers of mac_window.h get the same types,
// avoiding typedef redefinition errors when both headers are pulled in
// via @cImport in root.zig.
#include "backend.h"

// Window Management
void forge_mac_init(void);
void forge_mac_run(void);
void forge_mac_create_window(const char* title, int width, int height);
void forge_mac_request_redraw(void);
void forge_mac_set_continuous_rendering(bool enabled);
void forge_mac_get_render_stats(unsigned long long *redraw_requests, unsigned long long *frames);

void forge_mac_set_render_callback(ForgeRenderCallback callback);
void forge_mac_set_key_callback(ForgeKeyCallback callback);
void forge_mac_set_mouse_callback(ForgeMouseCallback callback);
void forge_mac_set_ime_composition_callback(ForgeImeCompositionCallback callback);
void forge_mac_set_ime_cursor_rect(float x, float y, float w, float h);
void forge_mac_set_cursor(int type);

void forge_mac_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a);
void forge_mac_draw_rounded_rect(float x, float y, float w, float h, float r, float g, float b, float a, float cornerRadius);
void forge_mac_draw_text(const char *text, float x, float y, float fontSize, float r, float g, float b, float a);
void forge_mac_draw_text_len(const char *text, size_t len, float x, float y, float fontSize, float r, float g, float b, float a);
void forge_mac_draw_svg(const char* svg_string, float x, float y, float w, float h, float r, float g, float b, float a);
void forge_mac_draw_styled_text(const char *text, size_t len, float x, float y, float fontSize, const ForgeTextSpan *spans, size_t span_count);
void forge_mac_set_text_style(const char *fontFamily, int fontWeight);
void forge_mac_set_editor_text_metrics(float editorFontSize, float lineHeight, float baseline);
void forge_mac_get_resolved_font_name(char *buf, size_t cap);
void forge_mac_get_font_metrics(float fontSize, float *charWidth, float *lineHeight, float *baseline);
float forge_mac_measure_text_width(const char *text, size_t len, float fontSize);
void forge_mac_get_window_size(float* w, float* h);
void forge_mac_set_clip_rect(float x, float y, float w, float h);
void forge_mac_clear_clip_rect(void);
void forge_mac_flush_batch(void);
void forge_mac_set_clipboard_text(const char* text, size_t len);
size_t forge_mac_get_clipboard_text(char* out, size_t cap);
int forge_mac_save_clipboard_png(const char* out_path);

#endif
