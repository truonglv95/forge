// OpenGL (GLX) backend for Forge IDE — GPU-accelerated rendering on Linux.
//
// Uses desktop OpenGL via GLX (X11 OpenGL extension) instead of EGL/GLES.
// GLX is available on any X11 system with Mesa/GL drivers — no extra
// dev packages needed beyond libGL.so.1 (already installed).
//
// This avoids the libegl1-mesa-dev / libgles2-mesa-dev dependency.
// Shaders use GLSL 1.30 (desktop OpenGL 3.0) instead of GLSL ES 3.0.

#include "../shared/backend.h"

#ifdef __linux__

#include <GL/glx.h>
#include <GL/gl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// --- GLSL Shaders (desktop OpenGL 1.30) ---

static const char* kRectVS =
    "#version 130\n"
    "in vec2 a_position;\n"
    "in vec4 a_color;\n"
    "uniform vec2 u_viewport;\n"
    "out vec4 v_color;\n"
    "void main() {\n"
    "    vec2 clip = a_position / u_viewport * 2.0 - 1.0;\n"
    "    gl_Position = vec4(clip.x, -clip.y, 0.0, 1.0);\n"
    "    v_color = a_color;\n"
    "}\n";

static const char* kRectFS =
    "#version 130\n"
    "in vec4 v_color;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    fragColor = v_color;\n"
    "}\n";

// --- GL state ---

static GLXContext g_glx_context = NULL;
static GLXFBConfig g_glx_config = NULL;
static GLuint g_rect_program = 0;
static GLuint g_rect_vbo = 0;
static int g_gl_initialized = 0;

// Batched rect vertices
#define GLX_MAX_RECT_VERTS 65536
typedef struct {
    float position[2];
    float color[4];
} GLXVertex;
static GLXVertex g_rect_verts[GLX_MAX_RECT_VERTS];
static int g_rect_count = 0;

// --- SDF text rendering ---

static const char* kTextVS =
    "#version 130\n"
    "in vec2 a_position;\n"
    "in vec2 a_texcoord;\n"
    "in vec4 a_color;\n"
    "uniform vec2 u_viewport;\n"
    "out vec2 v_texcoord;\n"
    "out vec4 v_color;\n"
    "void main() {\n"
    "    vec2 clip = a_position / u_viewport * 2.0 - 1.0;\n"
    "    gl_Position = vec4(clip.x, -clip.y, 0.0, 1.0);\n"
    "    v_texcoord = a_texcoord;\n"
    "    v_color = a_color;\n"
    "}\n";

static const char* kTextFS =
    "#version 130\n"
    "in vec2 v_texcoord;\n"
    "in vec4 v_color;\n"
    "uniform sampler2D u_atlas;\n"
    "uniform float u_smoothing;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    float dist = texture(u_atlas, v_texcoord).r;\n"
    "    float alpha = smoothstep(0.5 - u_smoothing, 0.5 + u_smoothing, dist);\n"
    "    fragColor = vec4(v_color.rgb, v_color.a * alpha);\n"
    "}\n";

typedef struct {
    float position[2];
    float texcoord[2];
    float color[4];
} TextVertex;

#define GLX_MAX_TEXT_VERTS 65536
static TextVertex g_text_verts[GLX_MAX_TEXT_VERTS];
static int g_text_count = 0;
static GLuint g_text_program = 0;
static GLuint g_text_vbo = 0;
static GLuint g_atlas_texture = 0;
static int g_atlas_loaded = 0;

// --- Shader compilation ---

static GLuint compile_shader_glx(GLenum type, const char* source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint compiled = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (!compiled) {
        char log[512];
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        fprintf(stderr, "[gpu_glx] shader error: %s\n", log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

static GLuint link_program_glx(GLuint vs, GLuint fs) {
    GLuint program = glCreateProgram();
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glLinkProgram(program);
    GLint linked = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) return 0;
    return program;
}

// --- Initialization ---

int forge_gpu_glx_init(void* x11_display, unsigned long x11_window) {
    Display* dpy = (Display*)x11_display;
    if (!dpy) return 0;

    int attribs[] = {
        GLX_RGBA, GLX_DOUBLEBUFFER,
        GLX_RED_SIZE, 8,
        GLX_GREEN_SIZE, 8,
        GLX_BLUE_SIZE, 8,
        GLX_ALPHA_SIZE, 8,
        GLX_DEPTH_SIZE, 0,
        None
    };

    int fb_count = 0;
    GLXFBConfig* fbc = glXChooseFBConfig(dpy, DefaultScreen(dpy), NULL, &fb_count);
    if (!fbc || fb_count == 0) {
        // Fallback: use glXChooseVisual
        XVisualInfo* vi = glXChooseVisual(dpy, DefaultScreen(dpy), attribs);
        if (!vi) return 0;
        g_glx_context = glXCreateContext(dpy, vi, NULL, GL_TRUE);
        XFree(vi);
    } else {
        g_glx_config = fbc[0];
        XVisualInfo* vi = glXGetVisualFromFBConfig(dpy, g_glx_config);
        if (vi) {
            g_glx_context = glXCreateContext(dpy, vi, NULL, GL_TRUE);
            XFree(vi);
        }
        XFree(fbc);
    }

    if (!g_glx_context) {
        fprintf(stderr, "[gpu_glx] cannot create GLX context\n");
        return 0;
    }

    if (!glXMakeCurrent(dpy, (Window)x11_window, g_glx_context)) {
        fprintf(stderr, "[gpu_glx] glXMakeCurrent failed\n");
        return 0;
    }

    // Compile shaders
    GLuint vs = compile_shader_glx(GL_VERTEX_SHADER, kRectVS);
    GLuint fs = compile_shader_glx(GL_FRAGMENT_SHADER, kRectFS);
    g_rect_program = link_program_glx(vs, fs);
    glDeleteShader(vs);
    glDeleteShader(fs);

    if (!g_rect_program) {
        fprintf(stderr, "[gpu_glx] shader program failed\n");
        return 0;
    }

    // Create VBO
    glGenBuffers(1, &g_rect_vbo);
    glBindBuffer(GL_ARRAY_BUFFER, g_rect_vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(GLXVertex) * GLX_MAX_RECT_VERTS, NULL, GL_DYNAMIC_DRAW);

    // Enable blending
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    g_gl_initialized = 1;
    fprintf(stderr, "[gpu_glx] initialized (OpenGL %s)\n", glGetString(GL_VERSION));
    return 1;
}

// --- Batched rect rendering ---

void forge_gpu_glx_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a) {
    if (g_rect_count + 6 > GLX_MAX_RECT_VERTS) return;
    int base = g_rect_count;
    g_rect_verts[base + 0] = (GLXVertex){{x, y}, {r, g, b, a}};
    g_rect_verts[base + 1] = (GLXVertex){{x + w, y}, {r, g, b, a}};
    g_rect_verts[base + 2] = (GLXVertex){{x, y + h}, {r, g, b, a}};
    g_rect_verts[base + 3] = (GLXVertex){{x + w, y}, {r, g, b, a}};
    g_rect_verts[base + 4] = (GLXVertex){{x + w, y + h}, {r, g, b, a}};
    g_rect_verts[base + 5] = (GLXVertex){{x, y + h}, {r, g, b, a}};
    g_rect_count += 6;
}

// --- Frame flush ---

void forge_gpu_glx_flush(float viewport_w, float viewport_h) {
    if (!g_gl_initialized || g_rect_count == 0) return;

    glViewport(0, 0, (int)viewport_w, (int)viewport_h);
    glUseProgram(g_rect_program);

    GLint loc = glGetUniformLocation(g_rect_program, "u_viewport");
    glUniform2f(loc, viewport_w, viewport_h);

    glBindBuffer(GL_ARRAY_BUFFER, g_rect_vbo);
    glBufferSubData(GL_ARRAY_BUFFER, 0, sizeof(GLXVertex) * g_rect_count, g_rect_verts);

    GLint pos_loc = glGetAttribLocation(g_rect_program, "a_position");
    GLint col_loc = glGetAttribLocation(g_rect_program, "a_color");
    glEnableVertexAttribArray(pos_loc);
    glVertexAttribPointer(pos_loc, 2, GL_FLOAT, GL_FALSE, sizeof(GLXVertex), (void*)0);
    glEnableVertexAttribArray(col_loc);
    glVertexAttribPointer(col_loc, 4, GL_FLOAT, GL_FALSE, sizeof(GLXVertex), (void*)8);

    glDrawArrays(GL_TRIANGLES, 0, g_rect_count);
    g_rect_count = 0;
}

// --- Present (swap buffers + VSync) ---

void forge_gpu_glx_present(void* x11_display, unsigned long x11_window) {
    Display* dpy = (Display*)x11_display;
    if (dpy && g_glx_context) {
        glXSwapBuffers(dpy, (Window)x11_window);
    }
}

// --- Clear ---

void forge_gpu_glx_clear(float r, float g, float b, float a) {
    glClearColor(r, g, b, a);
    glClear(GL_COLOR_BUFFER_BIT);
}

// --- Check availability ---

int forge_gpu_glx_available(void* x11_display) {
    Display* dpy = (Display*)x11_display;
    if (!dpy) return 0;
    return glXQueryExtension(dpy, NULL, NULL);
}

// --- SDF atlas texture upload ---

void forge_gpu_glx_load_atlas(const unsigned char* pixel_data, int width, int height) {
    if (!g_gl_initialized) return;
    glGenTextures(1, &g_atlas_texture);
    glBindTexture(GL_TEXTURE_2D, g_atlas_texture);
    glTexImage2D(GL_TEXTURE_2D, 0, 0x1903 /* GL_RED */, width, height, 0, 0x1903, 0x1401 /* GL_UNSIGNED_BYTE */, pixel_data);
    glTexParameteri(GL_TEXTURE_2D, 0x2801 /* GL_TEXTURE_MIN_FILTER */, 0x2601 /* GL_LINEAR */);
    glTexParameteri(GL_TEXTURE_2D, 0x2800 /* GL_TEXTURE_MAG_FILTER */, 0x2601 /* GL_LINEAR */);
    glTexParameteri(GL_TEXTURE_2D, 0x2802 /* GL_TEXTURE_WRAP_S */, 0x812F /* GL_CLAMP_TO_EDGE */);
    glTexParameteri(GL_TEXTURE_2D, 0x2803 /* GL_TEXTURE_WRAP_T */, 0x812F /* GL_CLAMP_TO_EDGE */);

    // Compile text shaders
    GLuint vs = compile_shader_glx(GL_VERTEX_SHADER, kTextVS);
    GLuint fs = compile_shader_glx(GL_FRAGMENT_SHADER, kTextFS);
    g_text_program = link_program_glx(vs, fs);
    glDeleteShader(vs);
    glDeleteShader(fs);

    // Create text VBO
    glGenBuffers(1, &g_text_vbo);
    glBindBuffer(GL_ARRAY_BUFFER, g_text_vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(TextVertex) * GLX_MAX_TEXT_VERTS, NULL, GL_DYNAMIC_DRAW);

    g_atlas_loaded = 1;
    fprintf(stderr, "[gpu_glx] SDF atlas loaded (%dx%d)\n", width, height);
}

// --- SDF text draw (batch a glyph quad) ---

void forge_gpu_glx_draw_text_quad(
    float x, float y, float w, float h,
    float u0, float v0, float u1, float v1,
    float r, float g, float b, float a
) {
    if (g_text_count + 6 > GLX_MAX_TEXT_VERTS) return;
    if (!g_atlas_loaded) return;
    int base = g_text_count;
    g_text_verts[base + 0] = (TextVertex){{x, y}, {u0, v0}, {r, g, b, a}};
    g_text_verts[base + 1] = (TextVertex){{x + w, y}, {u1, v0}, {r, g, b, a}};
    g_text_verts[base + 2] = (TextVertex){{x, y + h}, {u0, v1}, {r, g, b, a}};
    g_text_verts[base + 3] = (TextVertex){{x + w, y}, {u1, v0}, {r, g, b, a}};
    g_text_verts[base + 4] = (TextVertex){{x + w, y + h}, {u1, v1}, {r, g, b, a}};
    g_text_verts[base + 5] = (TextVertex){{x, y + h}, {u0, v1}, {r, g, b, a}};
    g_text_count += 6;
}

// --- Flush text batch ---

void forge_gpu_glx_flush_text(float viewport_w, float viewport_h, float smoothing) {
    if (!g_atlas_loaded || g_text_count == 0) return;

    glUseProgram(g_text_program);

    GLint loc = glGetUniformLocation(g_text_program, "u_viewport");
    glUniform2f(loc, viewport_w, viewport_h);
    GLint smooth_loc = glGetUniformLocation(g_text_program, "u_smoothing");
    if (smooth_loc >= 0) {
        /* smoothing = 1.0 / font_size — approx 0.07 for 14px */
        glUniform1f(smooth_loc, smoothing);
    }

    // Bind atlas texture
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, g_atlas_texture);
    GLint atlas_loc = glGetUniformLocation(g_text_program, "u_atlas");
    if (atlas_loc >= 0) glUniform1i(atlas_loc, 0);

    // Upload text vertices
    glBindBuffer(GL_ARRAY_BUFFER, g_text_vbo);
    glBufferSubData(GL_ARRAY_BUFFER, 0, sizeof(TextVertex) * g_text_count, g_text_verts);

    GLint pos_loc = glGetAttribLocation(g_text_program, "a_position");
    GLint uv_loc = glGetAttribLocation(g_text_program, "a_texcoord");
    GLint col_loc = glGetAttribLocation(g_text_program, "a_color");
    glEnableVertexAttribArray(pos_loc);
    glVertexAttribPointer(pos_loc, 2, GL_FLOAT, GL_FALSE, sizeof(TextVertex), (void*)0);
    glEnableVertexAttribArray(uv_loc);
    glVertexAttribPointer(uv_loc, 2, GL_FLOAT, GL_FALSE, sizeof(TextVertex), (void*)8);
    glEnableVertexAttribArray(col_loc);
    glVertexAttribPointer(col_loc, 4, GL_FLOAT, GL_FALSE, sizeof(TextVertex), (void*)16);

    glDrawArrays(GL_TRIANGLES, 0, g_text_count);
    g_text_count = 0;
}

#else // !__linux__

int forge_gpu_glx_init(void* d, unsigned long w) { (void)d; (void)w; return 0; }
void forge_gpu_glx_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a) { (void)x; (void)y; (void)w; (void)h; (void)r; (void)g; (void)b; (void)a; }
void forge_gpu_glx_flush(float vw, float vh) { (void)vw; (void)vh; }
void forge_gpu_glx_present(void* d, unsigned long w) { (void)d; (void)w; }
void forge_gpu_glx_clear(float r, float g, float b, float a) { (void)r; (void)g; (void)b; (void)a; }
int forge_gpu_glx_available(void* d) { (void)d; return 0; }
void forge_gpu_glx_load_atlas(const unsigned char* d, int w, int h) { (void)d; (void)w; (void)h; }
void forge_gpu_glx_draw_text_quad(float x, float y, float w, float h, float u0, float v0, float u1, float v1, float r, float g, float b, float a) { (void)x; (void)y; (void)w; (void)h; (void)u0; (void)v0; (void)u1; (void)v1; (void)r; (void)g; (void)b; (void)a; }
void forge_gpu_glx_flush_text(float vw, float vh, float s) { (void)vw; (void)vh; (void)s; }

#endif // __linux__
