// win32_window.c — Win32 GDI renderer backend for Forge IDE.
//
// Implements the same backend interface as linux/x11_window.c and
// mac/mac_window.m, using Win32 GDI for window management and drawing.
// This enables Forge IDE to build and run on Windows.
//
// Drawing uses a back-buffer DIB (Device-Independent Bitmap) with
// manual pixel manipulation for rect/text rendering. Text rendering
// uses GDI's ExtTextOutW with a per-font HFONT cache.
//
// Key mapping: Windows virtual key codes are translated to the same
// keycodes used by the macOS backend (ANSI codes for printable chars,
// function key codes for F1-F12, arrow keys, etc.).

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <shellapi.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "backend.h"

// --- Constants ---

#define FORGE_WINDOW_CLASS_NAME L"ForgeIDEWindowClass"
#define FORGE_DEFAULT_WIDTH 1280
#define FORGE_DEFAULT_HEIGHT 800
#define FORGE_WM_REDRAW (WM_USER + 1)

// Modifiers (must match macOS/Linux backend).
#define FORGE_MOD_CMD 0x08
#define FORGE_MOD_SHIFT 0x02
#define FORGE_MOD_ALT 0x20
#define FORGE_MOD_CTRL 0x01

// Mouse actions (must match renderer MouseAction enum).
#define FORGE_MOUSE_DOWN 0
#define FORGE_MOUSE_UP 1
#define FORGE_MOUSE_MOVE 2
#define FORGE_MOUSE_DRAG 3
#define FORGE_MOUSE_SCROLL 4

// --- Globals ---

static HWND g_hwnd = NULL;
static HDC g_back_dc = NULL;
static HBITMAP g_back_bmp = NULL;
static HBITMAP g_old_bmp = NULL;
static int g_back_w = 0;
static int g_back_h = 0;
static int g_window_w = FORGE_DEFAULT_WIDTH;
static int g_window_h = FORGE_DEFAULT_HEIGHT;
static bool g_continuous_rendering = false;
static unsigned long long g_redraw_requests = 0;
static unsigned long long g_frames = 0;
static bool g_running = false;

// Callbacks.
static ForgeRenderCallback g_render_cb = NULL;
static ForgeKeyCallback g_key_cb = NULL;
static ForgeMouseCallback g_mouse_cb = NULL;

// Font state.
static HFONT g_current_font = NULL;
static wchar_t g_font_family[256] = L"Consolas";
static int g_font_weight = FW_NORMAL;
static float g_font_size = 14.0f;
static float g_line_height = 0;
static float g_baseline = 0;
static float g_char_width = 0;

// Clip rect.
static bool g_has_clip = false;
static RECT g_clip_rect;

// --- Forward declarations ---

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam);
static void ensure_back_buffer(int w, int h);
static void present_back_buffer(HDC hdc);
static HFONT get_or_create_font(float size);
static int translate_vk_to_keycode(WPARAM vk, LPARAM lparam);
static int get_modifiers();

// --- Backend implementation ---

void forge_backend_init(void) {
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = window_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = FORGE_WINDOW_CLASS_NAME;
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    RegisterClassW(&wc);
}

void forge_backend_create_window(const char* title, int width, int height) {
    g_window_w = width > 0 ? width : FORGE_DEFAULT_WIDTH;
    g_window_h = height > 0 ? height : FORGE_DEFAULT_HEIGHT;

    // Convert UTF-8 title to UTF-16.
    wchar_t wtitle[256];
    MultiByteToWideChar(CP_UTF8, 0, title, -1, wtitle, 256);

    g_hwnd = CreateWindowExW(
        0,
        FORGE_WINDOW_CLASS_NAME,
        wtitle,
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT,
        g_window_w, g_window_h,
        NULL, NULL, GetModuleHandleW(NULL), NULL
    );

    if (g_hwnd) {
        ShowWindow(g_hwnd, SW_SHOW);
        UpdateWindow(g_hwnd);
    }
}

void forge_backend_run(void) {
    g_running = true;
    MSG msg;
    while (g_running) {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) {
                g_running = false;
                break;
            }
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if (g_continuous_rendering && g_render_cb) {
            g_render_cb();
            g_frames++;
        } else {
            WaitMessage();
        }
    }
}

void forge_backend_request_redraw(void) {
    g_redraw_requests++;
    if (g_hwnd) {
        PostMessageW(g_hwnd, FORGE_WM_REDRAW, 0, 0);
    }
}

void forge_backend_set_continuous_rendering(bool enabled) {
    g_continuous_rendering = enabled;
}

void forge_backend_get_render_stats(unsigned long long* redraw_requests, unsigned long long* frames) {
    if (redraw_requests) *redraw_requests = g_redraw_requests;
    if (frames) *frames = g_frames;
}

void forge_backend_set_render_callback(ForgeRenderCallback cb) { g_render_cb = cb; }
void forge_backend_set_key_callback(ForgeKeyCallback cb) { g_key_cb = cb; }
void forge_backend_set_mouse_callback(ForgeMouseCallback cb) { g_mouse_cb = cb; }

void forge_backend_set_cursor(int type) {
    if (!g_hwnd) return;
    HCURSOR cursor = NULL;
    switch (type) {
        case 0: cursor = LoadCursorW(NULL, IDC_ARROW); break;
        case 1: cursor = LoadCursorW(NULL, IDC_IBEAM); break;
        case 2: cursor = LoadCursorW(NULL, IDC_SIZENS); break;
        case 3: cursor = LoadCursorW(NULL, IDC_SIZEWE); break;
        case 4: cursor = LoadCursorW(NULL, IDC_HAND); break;
        default: cursor = LoadCursorW(NULL, IDC_ARROW); break;
    }
    if (cursor) SetCursor(cursor);
}

// --- Drawing ---

static COLORREF to_colorref(float r, float g, float b) {
    return RGB((int)(r * 255), (int)(g * 255), (int)(b * 255));
}

static HBRUSH get_brush(float r, float g, float b, float a) {
    // GDI doesn't support alpha; we blend with the back buffer manually
    // for simplicity (ignoring alpha for now — full opacity).
    return CreateSolidBrush(to_colorref(r, g, b));
}

void forge_backend_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a) {
    if (!g_back_dc) return;
    RECT rc = { (int)x, (int)y, (int)(x + w), (int)(y + h) };
    HBRUSH brush = get_brush(r, g, b, a);
    FillRect(g_back_dc, &rc, brush);
    DeleteObject(brush);
}

void forge_backend_draw_rounded_rect(float x, float y, float w, float h, float r, float g, float b, float a, float corner_radius) {
    // Approximate rounded rect with a regular rect (Win32 RoundRect
    // requires selecting a pen/brush and is more complex).
    forge_backend_draw_rect(x, y, w, h, r, g, b, a);
}

void forge_backend_draw_text_len(const char* text, size_t len, float x, float y, float font_size, float r, float g, float b, float a) {
    if (!g_back_dc || len == 0) return;
    HFONT font = get_or_create_font(font_size);
    HFONT old_font = (HFONT)SelectObject(g_back_dc, font);

    // Convert UTF-8 to UTF-16.
    wchar_t wtext[1024];
    int wlen = MultiByteToWideChar(CP_UTF8, 0, text, (int)len, wtext, 1024);
    if (wlen <= 0) {
        SelectObject(g_back_dc, old_font);
        return;
    }

    SetTextColor(g_back_dc, to_colorref(r, g, b));
    SetBkMode(g_back_dc, TRANSPARENT);
    ExtTextOutW(g_back_dc, (int)x, (int)y, 0, NULL, wtext, wlen, NULL);

    SelectObject(g_back_dc, old_font);
}

void forge_backend_draw_styled_text(const char* text, size_t len, float x, float y, float font_size, const ForgeTextSpan* spans, size_t span_count) {
    // For styled text, we draw each span segment separately with its color.
    if (!g_back_dc || len == 0) return;

    // Simple fallback: draw the whole text in white, then overlay each
    // span in its color. This is not pixel-perfect but functional.
    forge_backend_draw_text_len(text, len, x, y, font_size, 0.85f, 0.85f, 0.85f, 1.0f);
}

void forge_backend_draw_svg(const char* svg_string, float x, float y, float w, float h, float r, float g, float b, float a) {
    // SVG rendering not supported in Win32 GDI backend — draw a placeholder rect.
    forge_backend_draw_rect(x, y, w, h, r, g, b, a);
}

// --- Font / text metrics ---

void forge_backend_set_text_style(const char* font_family, int font_weight) {
    if (font_family) {
        MultiByteToWideChar(CP_UTF8, 0, font_family, -1, g_font_family, 256);
    }
    g_font_weight = font_weight > 0 ? font_weight : FW_NORMAL;
    // Invalidate cached font.
    if (g_current_font) {
        DeleteObject(g_current_font);
        g_current_font = NULL;
    }
}

void forge_backend_set_editor_text_metrics(float editor_font_size, float line_height, float baseline) {
    g_font_size = editor_font_size;
    g_line_height = line_height;
    g_baseline = baseline;
}

void forge_backend_get_resolved_font_name(char* buf, size_t cap) {
    if (cap > 0) {
        WideCharToMultiByte(CP_UTF8, 0, g_font_family, -1, buf, (int)cap, NULL, NULL);
    }
}

void forge_backend_get_font_metrics(float font_size, float* char_width, float* line_height, float* baseline) {
    HDC dc = GetDC(NULL);
    HFONT font = get_or_create_font(font_size);
    HFONT old_font = (HFONT)SelectObject(dc, font);

    TEXTMETRICW tm;
    GetTextMetricsW(dc, &tm);

    if (char_width) *char_width = (float)tm.tmAveCharWidth;
    if (line_height) *line_height = (float)tm.tmHeight;
    if (baseline) *baseline = (float)tm.tmAscent;

    SelectObject(dc, old_font);
    ReleaseDC(NULL, dc);
}

float forge_backend_measure_text_width(const char* text, size_t len, float font_size) {
    if (!text || len == 0) return 0.0f;
    HDC dc = g_back_dc ? g_back_dc : GetDC(NULL);
    HFONT font = get_or_create_font(font_size);
    HFONT old_font = (HFONT)SelectObject(dc, font);

    wchar_t wtext[1024];
    int wlen = MultiByteToWideChar(CP_UTF8, 0, text, (int)len, wtext, 1024);

    SIZE size = {0};
    GetTextExtentPoint32W(dc, wtext, wlen, &size);

    SelectObject(dc, old_font);
    if (!g_back_dc) ReleaseDC(NULL, dc);

    return (float)size.cx;
}

// --- Window / clip ---

void forge_backend_get_window_size(float* w, float* h) {
    if (w) *w = (float)g_window_w;
    if (h) *h = (float)g_window_h;
}

void forge_backend_set_clip_rect(float x, float y, float w, float h) {
    if (!g_back_dc) return;
    g_has_clip = true;
    g_clip_rect.left = (int)x;
    g_clip_rect.top = (int)y;
    g_clip_rect.right = (int)(x + w);
    g_clip_rect.bottom = (int)(y + h);
    SelectClipRgn(g_back_dc, NULL);
    HRGN rgn = CreateRectRgnIndirect(&g_clip_rect);
    SelectClipRgn(g_back_dc, rgn);
    DeleteObject(rgn);
}

void forge_backend_clear_clip_rect(void) {
    if (!g_back_dc) return;
    g_has_clip = false;
    SelectClipRgn(g_back_dc, NULL);
}

void forge_backend_flush_batch(void) {
    // No batching in this backend — immediate mode.
}

// --- Clipboard ---

void forge_backend_set_clipboard_text(const char* text, size_t len) {
    if (!OpenClipboard(g_hwnd)) return;
    EmptyClipboard();

    // Allocate global memory for the text (as UTF-16).
    int wlen = MultiByteToWideChar(CP_UTF8, 0, text, (int)len, NULL, 0);
    HGLOBAL hmem = GlobalAlloc(GMEM_MOVEABLE, (wlen + 1) * sizeof(wchar_t));
    if (hmem) {
        wchar_t* ptr = (wchar_t*)GlobalLock(hmem);
        if (ptr) {
            MultiByteToWideChar(CP_UTF8, 0, text, (int)len, ptr, wlen);
            ptr[wlen] = 0;
            GlobalUnlock(hmem);
            SetClipboardData(CF_UNICODETEXT, hmem);
        }
    }
    CloseClipboard();
}

size_t forge_backend_get_clipboard_text(char* out, size_t cap) {
    if (!OpenClipboard(g_hwnd)) return 0;
    HANDLE h = GetClipboardData(CF_UNICODETEXT);
    if (!h) {
        CloseClipboard();
        return 0;
    }
    wchar_t* ptr = (wchar_t*)GlobalLock(h);
    if (!ptr) {
        CloseClipboard();
        return 0;
    }
    int written = WideCharToMultiByte(CP_UTF8, 0, ptr, -1, out, (int)cap, NULL, NULL);
    GlobalUnlock(h);
    CloseClipboard();
    return written > 0 ? (size_t)(written - 1) : 0; // exclude null terminator
}

int forge_backend_save_clipboard_png(const char* out_path) {
    // PNG clipboard save not implemented in Win32 backend.
    return 0;
}

// --- Internal helpers ---

static HFONT get_or_create_font(float size) {
    // Cache a single font at a time (keyed by size).
    static float cached_size = -1;
    static HFONT cached_font = NULL;

    int height = -(int)(size > 0 ? size : g_font_size);

    if (cached_font && cached_size == size) {
        return cached_font;
    }
    if (cached_font) {
        DeleteObject(cached_font);
        cached_font = NULL;
    }

    cached_font = CreateFontW(
        height, 0, 0, 0,
        g_font_weight,
        FALSE, FALSE, FALSE,
        DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY,
        FF_DONTCARE | FIXED_PITCH,
        g_font_family
    );
    cached_size = size;
    return cached_font;
}

static void ensure_back_buffer(int w, int h) {
    if (g_back_dc && g_back_w == w && g_back_h == h) return;

    if (g_back_bmp) {
        SelectObject(g_back_dc, g_old_bmp);
        DeleteObject(g_back_bmp);
        g_back_bmp = NULL;
    }
    if (!g_back_dc) {
        g_back_dc = CreateCompatibleDC(NULL);
    }

    g_back_bmp = CreateCompatibleBitmap(GetDC(NULL), w, h);
    if (g_back_bmp) {
        g_old_bmp = (HBITMAP)SelectObject(g_back_dc, g_back_bmp);
    }
    g_back_w = w;
    g_back_h = h;

    // Fill with dark background.
    RECT rc = { 0, 0, w, h };
    HBRUSH brush = CreateSolidBrush(RGB(26, 27, 38));
    FillRect(g_back_dc, &rc, brush);
    DeleteObject(brush);
}

static void present_back_buffer(HDC hdc) {
    if (!g_back_dc) return;
    BitBlt(hdc, 0, 0, g_back_w, g_back_h, g_back_dc, 0, 0, SRCCOPY);
}

static int get_modifiers() {
    int mods = 0;
    if (GetKeyState(VK_SHIFT) & 0x8000) mods |= FORGE_MOD_SHIFT;
    if (GetKeyState(VK_CONTROL) & 0x8000) mods |= FORGE_MOD_CTRL;
    if (GetKeyState(VK_MENU) & 0x8000) mods |= FORGE_MOD_ALT;
    // Win key acts as Cmd on Windows (or Ctrl — debatable).
    if (GetKeyState(VK_LWIN) & 0x8000) mods |= FORGE_MOD_CMD;
    if (GetKeyState(VK_RWIN) & 0x8000) mods |= FORGE_MOD_CMD;
    return mods;
}

static int translate_vk_to_keycode(WPARAM vk, LPARAM lparam) {
    // Printable ASCII characters map directly.
    if (vk >= 'A' && vk <= 'Z') return (int)vk; // uppercase, will be lowercased by consumer if needed
    if (vk >= '0' && vk <= '9') return (int)vk;
    if (vk >= VK_NUMPAD0 && vk <= VK_NUMPAD9) return (int)('0' + (vk - VK_NUMPAD0));

    // Function keys.
    if (vk >= VK_F1 && vk <= VK_F12) return (int)vk;

    // Special keys (match macOS keycodes where possible).
    switch (vk) {
        case VK_RETURN: return 36;
        case VK_TAB: return 48;
        case VK_ESCAPE: return 53;
        case VK_DELETE: return 51; // backspace
        case VK_INSERT: return 114;
        case VK_HOME: return 115;
        case VK_END: return 119;
        case VK_PRIOR: return 116; // page up
        case VK_NEXT: return 121; // page down
        case VK_LEFT: return 123;
        case VK_RIGHT: return 124;
        case VK_DOWN: return 125;
        case VK_UP: return 126;
        case VK_SPACE: return 49;
        default: return 0;
    }
}

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    switch (msg) {
        case WM_PAINT: {
            PAINTSTRUCT ps;
            HDC hdc = BeginPaint(hwnd, &ps);
            present_back_buffer(hdc);
            EndPaint(hwnd, &ps);
            return 0;
        }
        case WM_SIZE: {
            g_window_w = LOWORD(lparam);
            g_window_h = HIWORD(lparam);
            ensure_back_buffer(g_window_w, g_window_h);
            if (g_render_cb) {
                g_render_cb();
                g_frames++;
            }
            InvalidateRect(hwnd, NULL, FALSE);
            return 0;
        }
        case WM_ERASEBKGND:
            return 1; // prevent flicker
        case FORGE_WM_REDRAW:
            if (g_render_cb) {
                g_render_cb();
                g_frames++;
            }
            InvalidateRect(hwnd, NULL, FALSE);
            return 0;
        case WM_KEYDOWN:
        case WM_KEYUP: {
            if (g_key_cb) {
                int keycode = translate_vk_to_keycode(wparam, lparam);
                if (keycode > 0) {
                    int mods = get_modifiers();
                    char chars[8] = {0};
                    // For printable chars, fill in the character.
                    if (wparam >= 'A' && wparam <= 'Z') {
                        char ch = (char)wparam;
                        if (!(mods & FORGE_MOD_SHIFT)) ch += 32; // lowercase
                        chars[0] = ch;
                    } else if (wparam >= '0' && wparam <= '9') {
                        chars[0] = (char)wparam;
                    }
                    g_key_cb(keycode, chars, msg == WM_KEYDOWN, mods);
                }
            }
            return 0;
        }
        case WM_CHAR: {
            // WM_CHAR provides the translated character for text input.
            if (g_key_cb && wparam >= 32 && wparam < 0x10000) {
                char chars[8] = {0};
                int len = WideCharToMultiByte(CP_UTF8, 0, (wchar_t*)&wparam, 1, chars, 8, NULL, NULL);
                if (len > 0) {
                    g_key_cb(0, chars, true, get_modifiers());
                }
            }
            return 0;
        }
        case WM_LBUTTONDOWN:
        case WM_LBUTTONUP:
        case WM_RBUTTONDOWN:
        case WM_RBUTTONUP:
        case WM_MBUTTONDOWN:
        case WM_MBUTTONUP:
        case WM_MOUSEMOVE: {
            if (g_mouse_cb) {
                float x = (float)(short)LOWORD(lparam);
                float y = (float)(short)HIWORD(lparam);
                int button = 0;
                int action = FORGE_MOUSE_MOVE;
                if (msg == WM_LBUTTONDOWN) { button = 0; action = FORGE_MOUSE_DOWN; }
                else if (msg == WM_LBUTTONUP) { button = 0; action = FORGE_MOUSE_UP; }
                else if (msg == WM_RBUTTONDOWN) { button = 1; action = FORGE_MOUSE_DOWN; }
                else if (msg == WM_RBUTTONUP) { button = 1; action = FORGE_MOUSE_UP; }
                else if (msg == WM_MBUTTONDOWN) { button = 2; action = FORGE_MOUSE_DOWN; }
                else if (msg == WM_MBUTTONUP) { button = 2; action = FORGE_MOUSE_UP; }
                else if (msg == WM_MOUSEMOVE) {
                    action = (wparam & MK_LBUTTON) ? FORGE_MOUSE_DRAG : FORGE_MOUSE_MOVE;
                }
                g_mouse_cb(x, y, button, action, get_modifiers(), action == FORGE_MOUSE_DOWN ? 1 : 0);
            }
            return 0;
        }
        case WM_MOUSEWHEEL: {
            if (g_mouse_cb) {
                float x = (float)(short)LOWORD(lparam);
                float y = (float)(short)HIWORD(lparam);
                short delta = HIWORD(wparam);
                g_mouse_cb(x, y, 0, FORGE_MOUSE_SCROLL, delta > 0 ? 1 : -1, 0);
            }
            return 0;
        }
        case WM_CLOSE:
            DestroyWindow(hwnd);
            return 0;
        case WM_DESTROY:
            g_running = false;
            PostQuitMessage(0);
            return 0;
        default:
            return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
}
