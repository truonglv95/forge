#ifndef FORGE_BACKEND_H
#define FORGE_BACKEND_H

#include <stdbool.h>
#include <stddef.h>

typedef struct {
    size_t offset;
    size_t length;
    float r, g, b, a;
} ForgeTextSpan;

void forge_backend_init(void);
void forge_backend_run(void);
void forge_backend_create_window(const char* title, int width, int height);
void forge_backend_request_redraw(void);
void forge_backend_set_continuous_rendering(bool enabled);
void forge_backend_get_render_stats(unsigned long long* redraw_requests, unsigned long long* frames);

typedef void (*ForgeRenderCallback)(void);
typedef void (*ForgeKeyCallback)(int keycode, const char* chars, bool is_down, int modifiers);
typedef void (*ForgeMouseCallback)(float x, float y, int button, int action, int modifiers);

void forge_backend_set_render_callback(ForgeRenderCallback cb);
void forge_backend_set_key_callback(ForgeKeyCallback cb);
void forge_backend_set_mouse_callback(ForgeMouseCallback cb);
void forge_backend_set_cursor(int type);

void forge_backend_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a);
void forge_backend_draw_rounded_rect(float x, float y, float w, float h, float r, float g, float b, float a, float corner_radius);
void forge_backend_draw_text_len(const char* text, size_t len, float x, float y, float font_size, float r, float g, float b, float a);
void forge_backend_draw_styled_text(const char* text, size_t len, float x, float y, float font_size, const ForgeTextSpan* spans, size_t span_count);
void forge_backend_draw_svg(const char* svg_string, float x, float y, float w, float h, float r, float g, float b, float a);

void forge_backend_set_text_style(const char* font_family, int font_weight);
void forge_backend_set_editor_text_metrics(float editor_font_size, float line_height, float baseline);
void forge_backend_get_resolved_font_name(char* buf, size_t cap);
void forge_backend_get_font_metrics(float font_size, float* char_width, float* line_height, float* baseline);
float forge_backend_measure_text_width(const char* text, size_t len, float font_size);

void forge_backend_get_window_size(float* w, float* h);
void forge_backend_set_clip_rect(float x, float y, float w, float h);
void forge_backend_clear_clip_rect(void);
void forge_backend_flush_batch(void);

void forge_backend_set_clipboard_text(const char* text, size_t len);
size_t forge_backend_get_clipboard_text(char* out, size_t cap);
int forge_backend_save_clipboard_png(const char* out_path);

#endif
