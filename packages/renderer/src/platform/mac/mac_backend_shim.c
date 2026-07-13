/*
 * macOS backend shim. Forwards forge_backend_* to the existing forge_mac_*
 * symbols. Compiled only on macOS alongside mac_window.m.
 */
#include "../shared/backend.h"

void forge_mac_init(void);
void forge_mac_run(void);
void forge_mac_create_window(const char* title, int width, int height);
void forge_mac_request_redraw(void);
void forge_mac_set_continuous_rendering(bool enabled);
void forge_mac_get_render_stats(unsigned long long* a, unsigned long long* b);
void forge_mac_set_render_callback(ForgeRenderCallback cb);
void forge_mac_set_key_callback(ForgeKeyCallback cb);
void forge_mac_set_mouse_callback(ForgeMouseCallback cb);
void forge_mac_set_cursor(int type);
void forge_mac_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a);
void forge_mac_draw_rounded_rect(float x, float y, float w, float h, float r, float g, float b, float a, float cr);
void forge_mac_draw_text_len(const char* text, size_t len, float x, float y, float fs, float r, float g, float b, float a);
void forge_mac_draw_styled_text(const char* text, size_t len, float x, float y, float fs, const ForgeTextSpan* spans, size_t n);
void forge_mac_draw_svg(const char* svg, float x, float y, float w, float h, float r, float g, float b, float a);
void forge_mac_set_text_style(const char* family, int weight);
void forge_mac_set_editor_text_metrics(float fs, float lh, float b);
void forge_mac_get_resolved_font_name(char* buf, size_t cap);
void forge_mac_get_font_metrics(float fs, float* cw, float* lh, float* bl);
float forge_mac_measure_text_width(const char* text, size_t len, float fs);
void forge_mac_get_window_size(float* w, float* h);
void forge_mac_set_clip_rect(float x, float y, float w, float h);
void forge_mac_clear_clip_rect(void);
void forge_mac_flush_batch(void);
void forge_mac_set_clipboard_text(const char* text, size_t len);
size_t forge_mac_get_clipboard_text(char* out, size_t cap);
int forge_mac_save_clipboard_png(const char* path);

void forge_backend_init(void) { forge_mac_init(); }
void forge_backend_run(void) { forge_mac_run(); }
void forge_backend_create_window(const char* t, int w, int h) { forge_mac_create_window(t, w, h); }
void forge_backend_request_redraw(void) { forge_mac_request_redraw(); }
void forge_backend_set_continuous_rendering(bool e) { forge_mac_set_continuous_rendering(e); }
void forge_backend_get_render_stats(unsigned long long* a, unsigned long long* b) { forge_mac_get_render_stats(a, b); }
void forge_backend_set_render_callback(ForgeRenderCallback cb) { forge_mac_set_render_callback(cb); }
void forge_backend_set_key_callback(ForgeKeyCallback cb) { forge_mac_set_key_callback(cb); }
void forge_backend_set_mouse_callback(ForgeMouseCallback cb) { forge_mac_set_mouse_callback(cb); }
void forge_backend_set_cursor(int t) { forge_mac_set_cursor(t); }
void forge_backend_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a) { forge_mac_draw_rect(x, y, w, h, r, g, b, a); }
void forge_backend_draw_rounded_rect(float x, float y, float w, float h, float r, float g, float b, float a, float cr) { forge_mac_draw_rounded_rect(x, y, w, h, r, g, b, a, cr); }
void forge_backend_draw_text_len(const char* t, size_t l, float x, float y, float fs, float r, float g, float b, float a) { forge_mac_draw_text_len(t, l, x, y, fs, r, g, b, a); }
void forge_backend_draw_styled_text(const char* t, size_t l, float x, float y, float fs, const ForgeTextSpan* s, size_t n) { forge_mac_draw_styled_text(t, l, x, y, fs, s, n); }
void forge_backend_draw_svg(const char* svg, float x, float y, float w, float h, float r, float g, float b, float a) { forge_mac_draw_svg(svg, x, y, w, h, r, g, b, a); }
void forge_backend_set_text_style(const char* f, int w) { forge_mac_set_text_style(f, w); }
void forge_backend_set_editor_text_metrics(float fs, float lh, float b) { forge_mac_set_editor_text_metrics(fs, lh, b); }
void forge_backend_get_resolved_font_name(char* buf, size_t cap) { forge_mac_get_resolved_font_name(buf, cap); }
void forge_backend_get_font_metrics(float fs, float* cw, float* lh, float* bl) { forge_mac_get_font_metrics(fs, cw, lh, bl); }
float forge_backend_measure_text_width(const char* t, size_t l, float fs) { return forge_mac_measure_text_width(t, l, fs); }
void forge_backend_get_window_size(float* w, float* h) { forge_mac_get_window_size(w, h); }
void forge_backend_set_clip_rect(float x, float y, float w, float h) { forge_mac_set_clip_rect(x, y, w, h); }
void forge_backend_clear_clip_rect(void) { forge_mac_clear_clip_rect(); }
void forge_backend_flush_batch(void) { forge_mac_flush_batch(); }
void forge_backend_set_clipboard_text(const char* t, size_t l) { forge_mac_set_clipboard_text(t, l); }
size_t forge_backend_get_clipboard_text(char* out, size_t cap) { return forge_mac_get_clipboard_text(out, cap); }
int forge_backend_save_clipboard_png(const char* p) { return forge_mac_save_clipboard_png(p); }
