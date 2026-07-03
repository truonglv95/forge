#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CoreText/CoreText.h>
#import "mac_window.h"

// --- Metal Types & Shaders ---
typedef struct {
    vector_float2 position;
    vector_float2 uv;
    vector_float4 color;
    vector_float4 sdf_params;
    vector_float4 sdf_params2;
} Vertex;

static const char* shaderSource = 
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VertexIn { float2 position; float2 uv; float4 color; float4 sdf_params; float4 sdf_params2; };\n"
"struct VertexOut { float4 position [[position]]; float2 uv; float4 color; float4 sdf_params; float4 sdf_params2; float2 pixelPos; };\n"
"vertex VertexOut vertexMain(uint vertexID [[vertex_id]], constant VertexIn *vertices [[buffer(0)]], constant float2 *viewportSize [[buffer(1)]]) {\n"
"    VertexOut out;\n"
"    float2 pixelSpacePosition = vertices[vertexID].position;\n"
"    float2 clipSpacePosition = (pixelSpacePosition / *viewportSize) * 2.0 - 1.0;\n"
"    out.position = float4(clipSpacePosition.x, -clipSpacePosition.y, 0.0, 1.0);\n" // Flip Y
"    out.uv = vertices[vertexID].uv;\n"
"    out.color = vertices[vertexID].color;\n"
"    out.sdf_params = vertices[vertexID].sdf_params;\n"
"    out.sdf_params2 = vertices[vertexID].sdf_params2;\n"
"    out.pixelPos = pixelSpacePosition;\n"
"    return out;\n"
"}\n"
"fragment float4 fragmentMain(VertexOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {\n"
"    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);\n"
"    float4 texColor = atlas.sample(s, in.uv);\n"
"    float4 finalColor = in.color * texColor;\n"
"    if (in.sdf_params2.x > 0.0) {\n"
"        float2 p = in.pixelPos - in.sdf_params.xy;\n"
"        float2 d = abs(p) - in.sdf_params.zw + in.sdf_params2.x;\n"
"        float dist = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - in.sdf_params2.x;\n"
"        float alpha = clamp(0.5 - dist, 0.0, 1.0);\n"
"        finalColor.a *= alpha;\n"
"    }\n"
"    return finalColor;\n"
"}\n";

// --- Glyph Atlas ---
@interface ForgeGlyphAtlas : NSObject
@property (strong) id<MTLTexture> texture;
@property (assign) CGContextRef bitmapContext;
@property (assign) uint8_t *bitmapData;
@property (strong) NSMutableDictionary *glyphCache;
@property (assign) int currentX;
@property (assign) int currentY;
@property (assign) int rowHeight;
@property (assign) BOOL needsUpload;
@end

@implementation ForgeGlyphAtlas
- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (self) {
        _glyphCache = [NSMutableDictionary new];
        _currentX = 1; // Start at 1, so (0,0) is reserved for solid color
        _currentY = 1;
        _rowHeight = 0;
        
        // 1. Create Bitmap Context (2048x2048 RGBA)
        int width = 2048;
        int height = 2048;
        _bitmapData = calloc(width * height * 4, 1);
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        _bitmapContext = CGBitmapContextCreate(_bitmapData, width, height, 8, width * 4, colorSpace, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(colorSpace);
        
        // Setup coordinate system (Standard Bottom-Left origin)
        // No CTM flip!
        
        // Fill (0, 2047) pixel with solid white for drawing rects
        // In Bottom-Left context, y=2047 is the top row in memory, mapping to uv=(0,0) in Metal texture.
        CGContextSetRGBFillColor(_bitmapContext, 1.0, 1.0, 1.0, 1.0);
        CGContextFillRect(_bitmapContext, CGRectMake(0, 2047, 1, 1));
        
        // 2. Create Metal Texture
        MTLTextureDescriptor *texDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
        texDesc.usage = MTLTextureUsageShaderRead;
        _texture = [device newTextureWithDescriptor:texDesc];
        
        _needsUpload = YES;
    }
    return self;
}

- (CGRect)getGlyphUV:(CGGlyph)glyph font:(CTFontRef)font {
    NSString *key = [NSString stringWithFormat:@"%p_%u", font, glyph];
    NSValue *cached = _glyphCache[key];
    if (cached) {
        return [cached rectValue];
    }
    
    // Not cached! Draw it to atlas.
    CGRect bounds;
    CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationDefault, &glyph, &bounds, 1);
    
    // CoreText bounds origin is the baseline. 
    // We need the physical bounding box to allocate space.
    int gw = ceil(bounds.size.width) + 2; // Add padding
    int gh = ceil(bounds.size.height) + 2;
    if (gw == 0 || gh == 0) gw = gh = 10; // Fallback
    
    if (_currentX + gw > 2048) {
        _currentX = 1;
        _currentY += _rowHeight;
        _rowHeight = 0;
    }
    if (gh > _rowHeight) {
        _rowHeight = gh;
    }
    
    if (_currentY + gh > 2048) {
        NSLog(@"Atlas full! Ignoring glyph.");
        return CGRectMake(0, 0, 0, 0);
    }
    
    CGContextSaveGState(_bitmapContext);
    
    // Explicitly configure text drawing
    CGContextSetTextDrawingMode(_bitmapContext, kCGTextFill);
    CGContextSetRGBFillColor(_bitmapContext, 1.0, 1.0, 1.0, 1.0);
    
    // No TextMatrix flip needed! We draw in standard Bottom-Left space.
    // _currentY is the bottom edge of our box.
    // bounds.origin.y is the distance from baseline to bottom of the glyph bounding box.
    // So the baseline is at `_currentY - bounds.origin.y`.
    CGFloat baselineX = _currentX + 1 - bounds.origin.x;
    CGFloat baselineY = _currentY + 1 - bounds.origin.y;
    CGPoint position = CGPointMake(baselineX, baselineY);
    
    CTFontDrawGlyphs(font, &glyph, &position, 1, _bitmapContext);
    
    CGContextRestoreGState(_bitmapContext);
    
    // Calculate UV (0.0 - 1.0)
    // Metal texture maps y=0 to top row in memory, which is y=2048 in CGContext.
    // Our box top is at `_currentY + gh`. So its distance from the top of the context is `2048 - (_currentY + gh)`.
    CGRect uv = CGRectMake((float)_currentX / 2048.0, 
                           (float)(2048 - _currentY - gh) / 2048.0, 
                           (float)gw / 2048.0, 
                           (float)gh / 2048.0);
                           
    // Save to cache
    _glyphCache[key] = [NSValue valueWithRect:uv];
    
    // We also need to save the physical bounds so we know how to offset the quad when drawing!
    // But for simplicity in this MVP, we will just use the UV rect to draw the exact box size!
    // We will pack the actual drawing offset into the cache value by slightly extending the struct or just passing it back.
    // Let's cheat for MVP: return the UV rect, and assume size is gw x gh.
    // We need `gw`, `gh` and `bounds.origin` to render correctly.
    // Instead of `uv` being just UV, let's make a custom struct later. 
    // Right now, return a rect: { uv.x, uv.y, gw, gh } 
    // Wait, `CGRect` has 4 floats. We can pack: { uv.x, uv.y, gw, gh }.
    CGRect packed = CGRectMake(uv.origin.x, uv.origin.y, gw, gh);
    _glyphCache[key] = [NSValue valueWithRect:packed];
    
    _currentX += gw;
    _needsUpload = YES;
    
    return packed;
}

- (void)uploadIfNeeded {
    if (_needsUpload) {
        [_texture replaceRegion:MTLRegionMake2D(0, 0, 2048, 2048) mipmapLevel:0 withBytes:_bitmapData bytesPerRow:2048*4];
        _needsUpload = NO;
    }
}
@end


// --- Global Renderer State ---
static ForgeRenderCallback g_renderCallback = NULL;

@interface ForgeRenderer : NSObject <MTKViewDelegate>
@property (strong) id<MTLDevice> device;
@property (strong) id<MTLCommandQueue> commandQueue;
@property (strong) id<MTLRenderPipelineState> pipelineState;

// Batching State
@property (strong) id<MTLBuffer> vertexBuffer;
@property (assign) NSUInteger vertexOffset;
@property (assign) NSUInteger vertexCount;
@property (assign) vector_float2 viewportSize;
@property (strong) id<MTLRenderCommandEncoder> currentEncoder;
@property (strong) ForgeGlyphAtlas *atlas;
@property (strong) MTKView *mtkView;
@end

@implementation ForgeRenderer
- (instancetype)initWithMetalKitView:(MTKView *)mtkView {
    self = [super init];
    if (self) {
        _mtkView = mtkView;
        _device = mtkView.device;
        _commandQueue = [_device newCommandQueue];
        
        _atlas = [[ForgeGlyphAtlas alloc] initWithDevice:_device];
        
        NSError *error = nil;
        id<MTLLibrary> defaultLibrary = [_device newLibraryWithSource:[NSString stringWithUTF8String:shaderSource] options:nil error:&error];
        if (!defaultLibrary) {
            NSLog(@"Failed to compile shader: %@", error);
            return nil;
        }
        
        id<MTLFunction> vertexFunction = [defaultLibrary newFunctionWithName:@"vertexMain"];
        id<MTLFunction> fragmentFunction = [defaultLibrary newFunctionWithName:@"fragmentMain"];
        
        MTLVertexDescriptor *vertexDescriptor = [[MTLVertexDescriptor alloc] init];
        vertexDescriptor.attributes[0].format = MTLVertexFormatFloat2;
        vertexDescriptor.attributes[0].offset = offsetof(Vertex, position);
        vertexDescriptor.attributes[0].bufferIndex = 0;
        vertexDescriptor.attributes[1].format = MTLVertexFormatFloat2;
        vertexDescriptor.attributes[1].offset = offsetof(Vertex, uv);
        vertexDescriptor.attributes[1].bufferIndex = 0;
        vertexDescriptor.attributes[2].format = MTLVertexFormatFloat4;
        vertexDescriptor.attributes[2].offset = offsetof(Vertex, color);
        vertexDescriptor.attributes[2].bufferIndex = 0;
        vertexDescriptor.attributes[3].format = MTLVertexFormatFloat4;
        vertexDescriptor.attributes[3].offset = offsetof(Vertex, sdf_params);
        vertexDescriptor.attributes[3].bufferIndex = 0;
        vertexDescriptor.attributes[4].format = MTLVertexFormatFloat4;
        vertexDescriptor.attributes[4].offset = offsetof(Vertex, sdf_params2);
        vertexDescriptor.attributes[4].bufferIndex = 0;
        vertexDescriptor.layouts[0].stride = sizeof(Vertex);
        vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
        
        MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
        pipelineStateDescriptor.label = @"Text & UI Pipeline";
        pipelineStateDescriptor.vertexFunction = vertexFunction;
        pipelineStateDescriptor.fragmentFunction = fragmentFunction;
        pipelineStateDescriptor.vertexDescriptor = vertexDescriptor;
        pipelineStateDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat;
        pipelineStateDescriptor.colorAttachments[0].blendingEnabled = YES;
        pipelineStateDescriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pipelineStateDescriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        pipelineStateDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pipelineStateDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
        pipelineStateDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pipelineStateDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        
        _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor error:&error];
        
        _vertexBuffer = [_device newBufferWithLength:sizeof(Vertex) * 50000 options:MTLResourceStorageModeShared];
    }
    return self;
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    _viewportSize.x = size.width;
    _viewportSize.y = size.height;
}

- (void)drawInMTKView:(MTKView *)view {
    _viewportSize.x = view.bounds.size.width;
    _viewportSize.y = view.bounds.size.height;
    
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    MTLRenderPassDescriptor *renderPassDescriptor = view.currentRenderPassDescriptor;
    
    if (renderPassDescriptor != nil) {
        _currentEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        [_currentEncoder setViewport:(MTLViewport){0.0, 0.0, view.drawableSize.width, view.drawableSize.height, -1.0, 1.0}];
        [_currentEncoder setRenderPipelineState:_pipelineState];
        
        _vertexOffset = 0;
        _vertexCount = 0;
        
        if (g_renderCallback) {
            g_renderCallback();
        }
        
        void forge_mac_flush_batch(void);
        forge_mac_flush_batch();
        
        [_currentEncoder endEncoding];
        [commandBuffer presentDrawable:view.currentDrawable];
    }
    _currentEncoder = nil;
    [commandBuffer commit];
}
@end

static ForgeKeyCallback g_keyCallback = NULL;
static ForgeMouseCallback g_mouseCallback = NULL;

@interface ForgeMTKView : MTKView
@end

@implementation ForgeMTKView
- (BOOL)acceptsFirstResponder { return YES; }

- (void)keyDown:(NSEvent *)event {
    if (g_keyCallback) {
        NSString *chars = [event characters];
        const char *cChars = chars ? [chars UTF8String] : "";
        g_keyCallback(event.keyCode, cChars, true, event.modifierFlags);
    }
}

- (void)keyUp:(NSEvent *)event {
    if (g_keyCallback) {
        g_keyCallback(event.keyCode, "", false, event.modifierFlags);
    }
}

- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    if (g_mouseCallback) {
        NSPoint location = [self convertPoint:[event locationInWindow] fromView:nil];
        g_mouseCallback(location.x, self.bounds.size.height - location.y, 0, 0); // 0 = Down
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (g_mouseCallback) {
        NSPoint location = [self convertPoint:[event locationInWindow] fromView:nil];
        g_mouseCallback(location.x, self.bounds.size.height - location.y, 0, 1); // 1 = Up
    }
}

- (void)mouseMoved:(NSEvent *)event {
    if (g_mouseCallback) {
        NSPoint location = [self convertPoint:[event locationInWindow] fromView:nil];
        g_mouseCallback(location.x, self.bounds.size.height - location.y, 0, 2); // 2 = Move
    }
}

- (void)mouseDragged:(NSEvent *)event {
    if (g_mouseCallback) {
        NSPoint location = [self convertPoint:[event locationInWindow] fromView:nil];
        g_mouseCallback(location.x, self.bounds.size.height - location.y, 0, 3); // 3 = Drag
    }
}

- (void)scrollWheel:(NSEvent *)event {
    if (g_mouseCallback) {
        g_mouseCallback(event.scrollingDeltaX, event.scrollingDeltaY, 0, 4); // 4 = Scroll
    }
}
@end

@interface ForgeWindow : NSWindow
@end

@implementation ForgeWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

static ForgeRenderer *g_renderer = nil;
static NSWindow *g_mainWindow = nil;

@interface ForgeAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (strong) NSWindow *window;
@property (strong) MTKView *mtkView;
@property (strong) ForgeRenderer *renderer;
@end

@implementation ForgeAppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp activateIgnoringOtherApps:YES];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}
@end

void forge_mac_init(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        ForgeAppDelegate *delegate = [[ForgeAppDelegate alloc] init];
        [app setDelegate:delegate];
    }
}

void forge_mac_create_window(const char* title, int width, int height) {
    @autoreleasepool {
        NSRect frame = NSMakeRect(0, 0, width, height);
        ForgeWindow *window = [[ForgeWindow alloc] initWithContentRect:frame
                                                       styleMask:NSWindowStyleMaskTitled |
                                                                 NSWindowStyleMaskClosable |
                                                                 NSWindowStyleMaskResizable |
                                                                 NSWindowStyleMaskMiniaturizable |
                                                                 NSWindowStyleMaskFullSizeContentView
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        window.titlebarAppearsTransparent = YES;
        window.titleVisibility = NSWindowTitleHidden;
        [window center];
        [window setTitle:[NSString stringWithUTF8String:title]];
        
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        ForgeMTKView *mtkView = [[ForgeMTKView alloc] initWithFrame:frame device:device];
        mtkView.clearColor = MTLClearColorMake(0.1, 0.1, 0.15, 1.0);
        
        window.acceptsMouseMovedEvents = YES;
        
        ForgeRenderer *renderer = [[ForgeRenderer alloc] initWithMetalKitView:mtkView];
        mtkView.delegate = renderer;
        g_renderer = renderer;
        
        window.contentView = mtkView;
        g_mainWindow = window;
        
        ForgeAppDelegate *delegate = (ForgeAppDelegate *)[NSApp delegate];
        delegate.window = window;
        delegate.mtkView = mtkView;
        delegate.renderer = renderer;
        
        [window makeKeyAndOrderFront:nil];
        [window makeFirstResponder:mtkView];
        [NSApp activateIgnoringOtherApps:YES];
    }
}

void forge_mac_run(void) {
    @autoreleasepool {
        [NSApp run];
    }
}

void forge_mac_set_render_callback(ForgeRenderCallback callback) {
    g_renderCallback = callback;
}

void forge_mac_set_key_callback(ForgeKeyCallback callback) {
    g_keyCallback = callback;
}

void forge_mac_set_mouse_callback(ForgeMouseCallback callback) {
    g_mouseCallback = callback;
}

void forge_mac_set_cursor(int type) {
    dispatch_async(dispatch_get_main_queue(), ^{
        switch (type) {
            case 0: [[NSCursor arrowCursor] set]; break;
            case 1: [[NSCursor IBeamCursor] set]; break;
            case 2: [[NSCursor resizeLeftRightCursor] set]; break;
            case 3: [[NSCursor resizeUpDownCursor] set]; break;
            default: [[NSCursor arrowCursor] set]; break;
        }
    });
}

void forge_mac_flush_batch(void) {
    if (!g_renderer || !g_renderer.currentEncoder || g_renderer.vertexCount == 0) return;
    
    [g_renderer.atlas uploadIfNeeded];
    [g_renderer.currentEncoder setFragmentTexture:g_renderer.atlas.texture atIndex:0];
    [g_renderer.currentEncoder setVertexBuffer:g_renderer.vertexBuffer offset:0 atIndex:0];
    
    vector_float2 vp = g_renderer.viewportSize;
    [g_renderer.currentEncoder setVertexBytes:&vp length:sizeof(vp) atIndex:1];
    
    [g_renderer.currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:g_renderer.vertexOffset vertexCount:g_renderer.vertexCount];
    
    g_renderer.vertexOffset += g_renderer.vertexCount;
    g_renderer.vertexCount = 0;
}

void forge_mac_set_clip_rect(float x, float y, float w, float h) {
    if (!g_renderer || !g_renderer.currentEncoder || !g_renderer.mtkView.window) return;
    forge_mac_flush_batch();
    
    CGFloat scale = g_renderer.mtkView.window.backingScaleFactor;
    
    float maxW = g_renderer.mtkView.drawableSize.width;
    float maxH = g_renderer.mtkView.drawableSize.height;
    
    float cx = fmax(0.0f, fmin(x * scale, maxW));
    float cy = fmax(0.0f, fmin(y * scale, maxH));
    float cw = fmax(0.0f, fmin(w * scale, maxW - cx));
    float ch = fmax(0.0f, fmin(h * scale, maxH - cy));
    
    MTLScissorRect rect = { (NSUInteger)cx, (NSUInteger)cy, (NSUInteger)cw, (NSUInteger)ch };
    if (rect.width > 0 && rect.height > 0) {
        [g_renderer.currentEncoder setScissorRect:rect];
    }
}

void forge_mac_clear_clip_rect(void) {
    if (!g_renderer || !g_renderer.currentEncoder) return;
    forge_mac_flush_batch();
    
    float maxW = g_renderer.mtkView.drawableSize.width;
    float maxH = g_renderer.mtkView.drawableSize.height;
    MTLScissorRect rect = { 0, 0, (NSUInteger)maxW, (NSUInteger)maxH };
    [g_renderer.currentEncoder setScissorRect:rect];
}

void forge_mac_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a) {
    if (!g_renderer || !g_renderer.currentEncoder) return;
    
    Vertex *vertexArray = (Vertex *)[g_renderer.vertexBuffer contents];
    NSUInteger idx = g_renderer.vertexOffset + g_renderer.vertexCount;
    if (idx + 6 > 50000) return;
    
    vector_float4 color = {r, g, b, a};
    // UV 0,0 is our white pixel in the Atlas
    vector_float2 uv = {0.0f, 0.0f}; 
    
    vector_float4 sdf_params = {0,0,0,0};
    vector_float4 sdf_params2 = {0,0,0,0};
    
    vertexArray[idx+0] = (Vertex){{x, y}, uv, color, sdf_params, sdf_params2};
    vertexArray[idx+1] = (Vertex){{x + w, y}, uv, color, sdf_params, sdf_params2};
    vertexArray[idx+2] = (Vertex){{x, y + h}, uv, color, sdf_params, sdf_params2};
    
    vertexArray[idx+3] = (Vertex){{x + w, y}, uv, color, sdf_params, sdf_params2};
    vertexArray[idx+4] = (Vertex){{x, y + h}, uv, color, sdf_params, sdf_params2};
    vertexArray[idx+5] = (Vertex){{x + w, y + h}, uv, color, sdf_params, sdf_params2};
    
    g_renderer.vertexCount += 6;
}

void forge_mac_draw_rounded_rect(float x, float y, float w, float h, float r, float g, float b, float a, float cornerRadius) {
    if (!g_renderer || !g_renderer.currentEncoder) return;
    
    Vertex *vertexArray = (Vertex *)[g_renderer.vertexBuffer contents];
    NSUInteger idx = g_renderer.vertexOffset + g_renderer.vertexCount;
    if (idx + 6 > 50000) return;
    
    vector_float4 color = {r, g, b, a};
    vector_float2 uv = {0.0f, 0.0f}; 
    vector_float4 sdf_params = {x + w/2.0f, y + h/2.0f, w/2.0f, h/2.0f};
    vector_float4 sdf_params2 = {cornerRadius, 0, 0, 0};
    
    vertexArray[idx+0] = (Vertex){{x, y}, uv, color, sdf_params, sdf_params2};
    vertexArray[idx+1] = (Vertex){{x + w, y}, uv, color, sdf_params, sdf_params2};
    vertexArray[idx+2] = (Vertex){{x, y + h}, uv, color, sdf_params, sdf_params2};
    
    vertexArray[idx+3] = (Vertex){{x + w, y}, uv, color, sdf_params, sdf_params2};
    vertexArray[idx+4] = (Vertex){{x, y + h}, uv, color, sdf_params, sdf_params2};
    vertexArray[idx+5] = (Vertex){{x + w, y + h}, uv, color, sdf_params, sdf_params2};
    
    g_renderer.vertexCount += 6;
}

void forge_mac_draw_text(const char* text, float x, float y, float fontSize, float r, float g, float b, float a) {
    if (!g_renderer || !g_renderer.currentEncoder) return;
    @autoreleasepool {
        CGFloat scale = 1.0;
        if (g_renderer.mtkView.window) {
            scale = g_renderer.mtkView.window.backingScaleFactor;
        }
        if (scale == 0) scale = 1.0;
        
        NSString *nsText = [NSString stringWithUTF8String:text];
        if (nsText.length == 0) return;
        
        CTFontRef font = CTFontCreateWithName((CFStringRef)@"Menlo", fontSize * scale, NULL);
        if (!font) return;
    
        NSArray<NSString*> *lines = [nsText componentsSeparatedByString:@"\n"];
        float currentY = y;
        float lineHeight = fontSize * 1.5f;
    
        for (NSString *lineStr in lines) {
            if (lineStr.length == 0) {
                currentY += lineHeight;
                continue;
            }
        
            NSDictionary *attributes = @{
                (id)kCTFontAttributeName: (__bridge id)font,
                (id)kCTForegroundColorAttributeName: (__bridge id)[NSColor whiteColor].CGColor
            };
        
            NSAttributedString *attrString = [[NSAttributedString alloc] initWithString:lineStr attributes:attributes];
            CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)attrString);
            
            CGFloat ascent, descent, leading;
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
            float logical_baseline = ascent / scale;
        
            CFArrayRef runs = CTLineGetGlyphRuns(line);
            CFIndex runCount = CFArrayGetCount(runs);
        
            vector_float4 color = {r, g, b, a};
            Vertex *vertexArray = (Vertex *)[g_renderer.vertexBuffer contents];
        
            for (CFIndex i = 0; i < runCount; i++) {
                CTRunRef run = CFArrayGetValueAtIndex(runs, i);
                CFIndex glyphCount = CTRunGetGlyphCount(run);
            
                CFDictionaryRef runAttributes = CTRunGetAttributes(run);
                CTFontRef runFont = CFDictionaryGetValue(runAttributes, kCTFontAttributeName);
                if (!runFont) runFont = font;
            
                CGGlyph glyphs[glyphCount];
                CGPoint positions[glyphCount];
                CTRunGetGlyphs(run, CFRangeMake(0, glyphCount), glyphs);
                CTRunGetPositions(run, CFRangeMake(0, glyphCount), positions);
            
                for (CFIndex j = 0; j < glyphCount; j++) {
                    CGRect packedInfo = [g_renderer.atlas getGlyphUV:glyphs[j] font:runFont];
                    if (packedInfo.size.width == 0) continue;
                
                    float uvX = packedInfo.origin.x;
                    float uvY = packedInfo.origin.y;
                    float gw = packedInfo.size.width;
                    float gh = packedInfo.size.height;
                
                    CGRect bounds;
                    CTFontGetBoundingRectsForGlyphs(runFont, kCTFontOrientationDefault, &glyphs[j], &bounds, 1);
                
                    float box_top_from_baseline = (bounds.size.height + bounds.origin.y) / scale;
                    float px = x + (positions[j].x / scale);
                    float py = currentY + logical_baseline - box_top_from_baseline;
                
                    float logical_gw = gw / scale;
                    float logical_gh = gh / scale;
                
                    NSUInteger idx = g_renderer.vertexOffset + g_renderer.vertexCount;
                    if (idx + 6 > 50000) break;
                
                    float uvW = gw / 2048.0f;
                    float uvH = gh / 2048.0f;
                
                    vector_float4 sdf_params = {0,0,0,0};
                    vector_float4 sdf_params2 = {0,0,0,0};

                    vertexArray[idx+0] = (Vertex){{px, py}, {uvX, uvY}, color, sdf_params, sdf_params2};
                    vertexArray[idx+1] = (Vertex){{px + logical_gw, py}, {uvX + uvW, uvY}, color, sdf_params, sdf_params2};
                    vertexArray[idx+2] = (Vertex){{px, py + logical_gh}, {uvX, uvY + uvH}, color, sdf_params, sdf_params2};
                    
                    vertexArray[idx+3] = (Vertex){{px + logical_gw, py}, {uvX + uvW, uvY}, color, sdf_params, sdf_params2};
                    vertexArray[idx+4] = (Vertex){{px, py + logical_gh}, {uvX, uvY + uvH}, color, sdf_params, sdf_params2};
                    vertexArray[idx+5] = (Vertex){{px + logical_gw, py + logical_gh}, {uvX + uvW, uvY + uvH}, color, sdf_params, sdf_params2};
                
                    g_renderer.vertexCount += 6;
                }
            }
        
            CFRelease(line);
            currentY += lineHeight;
        }
    
        CFRelease(font);
    }
}

void forge_mac_get_window_size(float* w, float* h) {
    if (g_mainWindow && g_mainWindow.contentView) {
        CGSize size = g_mainWindow.contentView.bounds.size;
        *w = size.width;
        *h = size.height;
    } else {
        *w = 1024;
        *h = 768;
    }
}
