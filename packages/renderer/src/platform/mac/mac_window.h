#ifndef MAC_WINDOW_H
#define MAC_WINDOW_H

#include <stdbool.h>

// Window Management
void forge_mac_init(void);
void forge_mac_run(void);
void forge_mac_create_window(const char* title, int width, int height);

typedef void (*ForgeRenderCallback)(void);
typedef void (*ForgeKeyCallback)(int keycode, const char* chars, bool isDown, int modifiers);
typedef void (*ForgeMouseCallback)(float x, float y, int button, int action);

void forge_mac_set_render_callback(ForgeRenderCallback callback);
void forge_mac_set_key_callback(ForgeKeyCallback callback);
void forge_mac_set_mouse_callback(ForgeMouseCallback callback);
void forge_mac_set_cursor(int type);

void forge_mac_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a);
void forge_mac_draw_rounded_rect(float x, float y, float w, float h, float r, float g, float b, float a, float cornerRadius);
void forge_mac_draw_text(const char *text, float x, float y, float fontSize, float r, float g, float b, float a);
void forge_mac_get_window_size(float* w, float* h);
void forge_mac_set_clip_rect(float x, float y, float w, float h);
void forge_mac_clear_clip_rect(void);

#endif
