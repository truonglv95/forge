#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CoreText/CoreText.h>
#import <string.h>
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
"    constexpr sampler atlasSampler(coord::normalized, address::clamp_to_edge, filter::nearest);\n"
"    float4 texColor = atlas.sample(atlasSampler, in.uv);\n"
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
        
        CGContextSetAllowsAntialiasing(_bitmapContext, YES);
        CGContextSetShouldAntialias(_bitmapContext, YES);
        CGContextSetAllowsFontSubpixelPositioning(_bitmapContext, YES);
        CGContextSetShouldSubpixelPositionFonts(_bitmapContext, YES);
        CGContextSetAllowsFontSubpixelQuantization(_bitmapContext, YES);
        CGContextSetShouldSubpixelQuantizeFonts(_bitmapContext, YES);
        CGContextSetInterpolationQuality(_bitmapContext, kCGInterpolationNone);
        
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
    CFStringRef postScriptName = CTFontCopyPostScriptName(font);
    NSString *key = [NSString stringWithFormat:@"%@_%.1f_%u",
                     (__bridge NSString *)postScriptName,
                     CTFontGetSize(font),
                     glyph];
    if (postScriptName) CFRelease(postScriptName);
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

- (void)resetGlyphs {
    [_glyphCache removeAllObjects];
    _currentX = 1;
    _currentY = 1;
    _rowHeight = 0;
    memset(_bitmapData, 0, 2048 * 2048 * 4);
    CGContextSetRGBFillColor(_bitmapContext, 1.0, 1.0, 1.0, 1.0);
    CGContextFillRect(_bitmapContext, CGRectMake(0, 2047, 1, 1));
    _needsUpload = YES;
}
@end


// --- Global Renderer State ---
static ForgeRenderCallback g_renderCallback = NULL;
static const NSUInteger kMaxVertices = 512000;

@class ForgeRenderer;
static void forge_mac_flush_batch(void);
static void ForgeEnsureVertexCapacity(NSUInteger needed);
static CTFontRef ForgeGetFont(CGFloat pixelSize);
static void ForgeInvalidateFontCache(void);
static ForgeRenderer *g_renderer = nil;

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
        
        _vertexBuffer = [_device newBufferWithLength:sizeof(Vertex) * kMaxVertices options:MTLResourceStorageModeShared];
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

    // Upload glyph atlas before the render pass — never during it (avoids GPU flicker).
    [_atlas uploadIfNeeded];
    
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
        
        forge_mac_flush_batch();
        
        [_currentEncoder endEncoding];
        [_atlas uploadIfNeeded];
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

static int ForgeMapModifiers(NSEventModifierFlags flags) {
    int mapped = 0;
    if (flags & NSEventModifierFlagCommand) mapped |= 0x08;
    if (flags & NSEventModifierFlagShift) mapped |= 0x02;
    if (flags & NSEventModifierFlagOption) mapped |= 0x20;
    if (flags & NSEventModifierFlagControl) mapped |= 0x01;
    return mapped;
}

- (void)keyDown:(NSEvent *)event {
    if (g_keyCallback) {
        NSString *chars = nil;
        const NSEventModifierFlags flags = event.modifierFlags;
        if ((flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) == 0) {
            chars = [event charactersIgnoringModifiers];
        }
        if (chars == nil || chars.length == 0) {
            chars = [event characters];
        }
        const char *cChars = chars ? [chars UTF8String] : "";
        g_keyCallback(event.keyCode, cChars, true, ForgeMapModifiers(event.modifierFlags));
    }
}

- (void)keyUp:(NSEvent *)event {
    if (g_keyCallback) {
        g_keyCallback(event.keyCode, "", false, ForgeMapModifiers(event.modifierFlags));
    }
}

- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    if (g_mouseCallback) {
        NSPoint location = [self convertPoint:[event locationInWindow] fromView:nil];
        g_mouseCallback(location.x, self.bounds.size.height - location.y, 0, 0, ForgeMapModifiers(event.modifierFlags));
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (g_mouseCallback) {
        NSPoint location = [self convertPoint:[event locationInWindow] fromView:nil];
        g_mouseCallback(location.x, self.bounds.size.height - location.y, 0, 1, ForgeMapModifiers(event.modifierFlags));
    }
}

- (void)mouseMoved:(NSEvent *)event {
    if (g_mouseCallback) {
        NSPoint location = [self convertPoint:[event locationInWindow] fromView:nil];
        g_mouseCallback(location.x, self.bounds.size.height - location.y, 0, 2, ForgeMapModifiers(event.modifierFlags));
    }
}

- (void)mouseDragged:(NSEvent *)event {
    if (g_mouseCallback) {
        NSPoint location = [self convertPoint:[event locationInWindow] fromView:nil];
        g_mouseCallback(location.x, self.bounds.size.height - location.y, 0, 3, ForgeMapModifiers(event.modifierFlags));
    }
}

- (void)scrollWheel:(NSEvent *)event {
    if (g_mouseCallback) {
        g_mouseCallback(event.scrollingDeltaX, event.scrollingDeltaY, 0, 4, ForgeMapModifiers(event.modifierFlags));
    }
}
@end

@interface ForgeWindow : NSWindow
@end

@implementation ForgeWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

static NSWindow *g_mainWindow = nil;
static NSString *g_fontFamilyStack = @"Menlo";
static int g_fontWeight = 0;
static float g_editorFontSize = 0;
static float g_editorLineHeight = 0;
static float g_editorBaseline = 0;
static char g_resolvedFontName[128] = "Menlo";

static float ForgeSnap(float value, float scale) {
    if (scale <= 0.0f) return value;
    return roundf(value * scale) / scale;
}

static void ForgeUpdateResolvedFontName(CGFloat pixelSize) {
    CTFontRef font = ForgeGetFont(pixelSize);
    if (!font) return;
    CFStringRef name = CTFontCopyDisplayName(font);
    if (!name) return;
    CFStringGetCString(name, g_resolvedFontName, sizeof(g_resolvedFontName), kCFStringEncodingUTF8);
    CFRelease(name);
}

static CTFontRef ForgeApplyEditorFeatures(CTFontRef font, CGFloat pixelSize) {
    if (!font) return NULL;

    CTFontDescriptorRef baseDesc = CTFontCopyFontDescriptor(font);
    CFDictionaryRef baseAttrs = CTFontDescriptorCopyAttributes(baseDesc);
    CFRelease(baseDesc);

    NSMutableDictionary *merged = baseAttrs
        ? [(__bridge NSDictionary *)baseAttrs mutableCopy]
        : [NSMutableDictionary dictionary];
    if (baseAttrs) CFRelease(baseAttrs);

    merged[(id)kCTFontFeatureSettingsAttribute] = @[@{
        (id)kCTFontFeatureTypeIdentifierKey: @(kLigaturesType),
        (id)kCTFontFeatureSelectorIdentifierKey: @(kCommonLigaturesOffSelector),
    }];

    CTFontDescriptorRef featuredDesc = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)merged);
    if (!featuredDesc) return font;

    CTFontRef featured = CTFontCreateWithFontDescriptor(featuredDesc, pixelSize, NULL);
    CFRelease(featuredDesc);
    if (!featured) return font;

    CFRelease(font);
    return featured;
}

static vector_float4 ForgeColorFromRun(CTRunRef run, vector_float4 fallback) {
    CFDictionaryRef attrs = CTRunGetAttributes(run);
    CGColorRef cgColor = CFDictionaryGetValue(attrs, kCTForegroundColorAttributeName);
    if (!cgColor) return fallback;

    size_t componentCount = CGColorGetNumberOfComponents(cgColor);
    const CGFloat *components = CGColorGetComponents(cgColor);
    if (!components || componentCount < 3) return fallback;

    return (vector_float4){
        (float)components[0],
        (float)components[1],
        (float)components[2],
        componentCount >= 4 ? (float)components[3] : 1.0f
    };
}

static void ForgeDrawGlyphsFromCTLine(CTLineRef line, CTFontRef defaultFont, float x, float y, float scale, vector_float4 fallbackColor) {
    if (!line || !g_renderer || !g_renderer.currentEncoder) return;

    CGFloat ascent = 0;
    CTLineGetTypographicBounds(line, &ascent, NULL, NULL);
    float logical_baseline = (float)(ascent / scale);
    float originX = ForgeSnap(x, scale);

    CFArrayRef runs = CTLineGetGlyphRuns(line);
    CFIndex runCount = CFArrayGetCount(runs);
    Vertex *vertexArray = (Vertex *)[g_renderer.vertexBuffer contents];

    for (CFIndex i = 0; i < runCount; i++) {
        CTRunRef run = CFArrayGetValueAtIndex(runs, i);
        CFIndex glyphCount = CTRunGetGlyphCount(run);

        CFDictionaryRef runAttributes = CTRunGetAttributes(run);
        CTFontRef runFont = CFDictionaryGetValue(runAttributes, kCTFontAttributeName);
        if (!runFont) runFont = defaultFont;

        vector_float4 color = ForgeColorFromRun(run, fallbackColor);

        CGGlyph glyphs[glyphCount];
        CGPoint positions[glyphCount];
        CTRunGetGlyphs(run, CFRangeMake(0, glyphCount), glyphs);
        CTRunGetPositions(run, CFRangeMake(0, glyphCount), positions);

        for (CFIndex j = 0; j < glyphCount; j++) {
            ForgeEnsureVertexCapacity(6);
            CGRect packedInfo = [g_renderer.atlas getGlyphUV:glyphs[j] font:runFont];
            if (packedInfo.size.width == 0) continue;

            float uvX = (float)packedInfo.origin.x;
            float uvY = (float)packedInfo.origin.y;
            float gw = (float)packedInfo.size.width;
            float gh = (float)packedInfo.size.height;

            CGRect bounds;
            CTFontGetBoundingRectsForGlyphs(runFont, kCTFontOrientationDefault, &glyphs[j], &bounds, 1);

            float box_top_from_baseline = (float)((bounds.size.height + bounds.origin.y) / scale);
            float px = ForgeSnap(originX + (positions[j].x / scale), scale);
            float py = ForgeSnap(y + logical_baseline - box_top_from_baseline, scale);

            float logical_gw = gw / scale;
            float logical_gh = gh / scale;

            NSUInteger idx = g_renderer.vertexOffset + g_renderer.vertexCount;
            if (idx + 6 > kMaxVertices) return;

            float uvW = gw / 2048.0f;
            float uvH = gh / 2048.0f;

            vector_float4 sdf_params = {0, 0, 0, 0};
            vector_float4 sdf_params2 = {0, 0, 0, 0};

            vertexArray[idx + 0] = (Vertex){{px, py}, {uvX, uvY}, color, sdf_params, sdf_params2};
            vertexArray[idx + 1] = (Vertex){{px + logical_gw, py}, {uvX + uvW, uvY}, color, sdf_params, sdf_params2};
            vertexArray[idx + 2] = (Vertex){{px, py + logical_gh}, {uvX, uvY + uvH}, color, sdf_params, sdf_params2};
            vertexArray[idx + 3] = (Vertex){{px + logical_gw, py}, {uvX + uvW, uvY}, color, sdf_params, sdf_params2};
            vertexArray[idx + 4] = (Vertex){{px, py + logical_gh}, {uvX, uvY + uvH}, color, sdf_params, sdf_params2};
            vertexArray[idx + 5] = (Vertex){{px + logical_gw, py + logical_gh}, {uvX + uvW, uvY + uvH}, color, sdf_params, sdf_params2};

            g_renderer.vertexCount += 6;
        }
    }
}

static CGFloat ForgeFontWeightValue(int fontWeight) {
    switch (fontWeight) {
        case 1: return NSFontWeightMedium;
        case 2: return NSFontWeightSemibold;
        case 3: return NSFontWeightBold;
        default: return NSFontWeightRegular;
    }
}

static CTFontRef ForgeApplyWeight(CTFontRef base, CGFloat pixelSize) {
    if (!base) return NULL;
    if (g_fontWeight == 0) return base;

    if (g_fontWeight == 3) {
        CTFontRef styled = CTFontCreateCopyWithSymbolicTraits(base, pixelSize, NULL, kCTFontBoldTrait, kCTFontBoldTrait);
        if (styled) {
            CFRelease(base);
            return styled;
        }
        return base;
    }

    CTFontDescriptorRef baseDesc = CTFontCopyFontDescriptor(base);
    CFDictionaryRef baseAttrs = CTFontDescriptorCopyAttributes(baseDesc);
    CFRelease(baseDesc);

    NSMutableDictionary *merged = baseAttrs
        ? [(__bridge NSDictionary *)baseAttrs mutableCopy]
        : [NSMutableDictionary dictionary];
    if (baseAttrs) CFRelease(baseAttrs);

    merged[(id)CFSTR("NSCTFontWeightAttribute")] = @(ForgeFontWeightValue(g_fontWeight));
    CTFontDescriptorRef weightedDesc = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)merged);
    if (!weightedDesc) return base;

    CTFontRef styled = CTFontCreateWithFontDescriptor(weightedDesc, pixelSize, NULL);
    CFRelease(weightedDesc);
    if (!styled) return base;

    CFRelease(base);
    return styled;
}

static CTFontRef ForgeCreateFont(CGFloat pixelSize) {
    NSArray<NSString *> *parts = [g_fontFamilyStack componentsSeparatedByString:@","];
    for (NSString *rawPart in parts) {
        NSString *name = [rawPart stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (name.length >= 2 && ([name hasPrefix:@"'"] || [name hasPrefix:@"\""])) {
            name = [name substringWithRange:NSMakeRange(1, name.length - 2)];
        }
        if ([name caseInsensitiveCompare:@"monospace"] == NSOrderedSame) continue;
        CTFontRef base = CTFontCreateWithName((CFStringRef)name, pixelSize, NULL);
        if (!base) continue;
        return ForgeApplyEditorFeatures(ForgeApplyWeight(base, pixelSize), pixelSize);
    }
    CTFontRef fallback = CTFontCreateWithName(CFSTR("Menlo"), pixelSize, NULL);
    return ForgeApplyEditorFeatures(ForgeApplyWeight(fallback, pixelSize), pixelSize);
}

static CTFontRef g_fontCache[12];
static CGFloat g_fontCacheSizes[12];
static int g_fontCacheCount = 0;

static void ForgeInvalidateFontCache(void) {
    for (int i = 0; i < g_fontCacheCount; i++) {
        if (g_fontCache[i]) CFRelease(g_fontCache[i]);
        g_fontCache[i] = NULL;
        g_fontCacheSizes[i] = 0;
    }
    g_fontCacheCount = 0;
    if (g_renderer && g_renderer.atlas) {
        [g_renderer.atlas resetGlyphs];
    }
}

static CTFontRef ForgeGetFont(CGFloat pixelSize) {
    for (int i = 0; i < g_fontCacheCount; i++) {
        if (g_fontCacheSizes[i] == pixelSize) return g_fontCache[i];
    }

    CTFontRef font = ForgeCreateFont(pixelSize);
    if (!font) return NULL;

    if (g_fontCacheCount < 12) {
        g_fontCache[g_fontCacheCount] = font;
        g_fontCacheSizes[g_fontCacheCount] = pixelSize;
        g_fontCacheCount++;
        return font;
    }

    CFRelease(g_fontCache[0]);
    for (int i = 1; i < 12; i++) {
        g_fontCache[i - 1] = g_fontCache[i];
        g_fontCacheSizes[i - 1] = g_fontCacheSizes[i];
    }
    g_fontCache[11] = font;
    g_fontCacheSizes[11] = pixelSize;
    return font;
}

static void ForgeEnsureVertexCapacity(NSUInteger needed) {
    if (!g_renderer) return;
    if (g_renderer.vertexOffset + g_renderer.vertexCount + needed <= kMaxVertices) return;
    forge_mac_flush_batch();
    if (g_renderer.vertexOffset + needed > kMaxVertices) {
        g_renderer.vertexOffset = 0;
    }
}

static CGFloat ForgeBackingScale(void) {
    if (g_renderer && g_renderer.mtkView.window) {
        CGFloat scale = g_renderer.mtkView.window.backingScaleFactor;
        if (scale > 0) return scale;
    }
    return 1.0;
}

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
    
    ForgeEnsureVertexCapacity(6);
    Vertex *vertexArray = (Vertex *)[g_renderer.vertexBuffer contents];
    NSUInteger idx = g_renderer.vertexOffset + g_renderer.vertexCount;
    if (idx + 6 > kMaxVertices) return;
    
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
    
    ForgeEnsureVertexCapacity(6);
    Vertex *vertexArray = (Vertex *)[g_renderer.vertexBuffer contents];
    NSUInteger idx = g_renderer.vertexOffset + g_renderer.vertexCount;
    if (idx + 6 > kMaxVertices) return;
    
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

void forge_mac_set_text_style(const char* fontFamily, int fontWeight) {
    BOOL styleChanged = NO;
    if (fontFamily && fontFamily[0] != '\0') {
        NSString *next = [NSString stringWithUTF8String:fontFamily];
        if (![next isEqualToString:g_fontFamilyStack]) {
            g_fontFamilyStack = next;
            styleChanged = YES;
        }
    }
    if (fontWeight != g_fontWeight) {
        g_fontWeight = fontWeight;
        styleChanged = YES;
    }
    if (styleChanged) {
        ForgeInvalidateFontCache();
        if (g_editorFontSize > 0) {
            ForgeUpdateResolvedFontName(g_editorFontSize * ForgeBackingScale());
        }
    }
}

void forge_mac_set_editor_text_metrics(float editorFontSize, float lineHeight, float baseline) {
    g_editorFontSize = editorFontSize;
    g_editorLineHeight = lineHeight;
    g_editorBaseline = baseline;
    ForgeUpdateResolvedFontName(editorFontSize * ForgeBackingScale());
}

void forge_mac_get_resolved_font_name(char* buf, size_t cap) {
    if (!buf || cap == 0) return;
    strncpy(buf, g_resolvedFontName, cap - 1);
    buf[cap - 1] = '\0';
}

static float ForgeLineHeightForFont(float fontSize) {
    if (g_editorLineHeight > 0.0f && fabsf(fontSize - g_editorFontSize) < 0.01f) {
        return g_editorLineHeight;
    }
    return fontSize * 1.35f;
}

void forge_mac_get_font_metrics(float fontSize, float* outCharWidth, float* outLineHeight, float* outBaseline) {
    if (!outCharWidth || !outLineHeight || !outBaseline) return;
    @autoreleasepool {
        CGFloat scale = ForgeBackingScale();
        CTFontRef font = ForgeGetFont(fontSize * scale);
        if (!font) return;

        UniChar chars[2] = {'m', ' '};
        CGGlyph glyphs[2];
        CGSize advances[2] = {{0, 0}, {0, 0}};
        if (CTFontGetGlyphsForCharacters(font, chars, glyphs, 2)) {
            CTFontGetAdvancesForGlyphs(font, kCTFontOrientationDefault, glyphs, advances, 2);
        }
        *outCharWidth = (float)(fmax(advances[0].width, advances[1].width) / scale);
        if (*outCharWidth <= 0) *outCharWidth = fontSize * 0.6f;

        *outBaseline = (float)(CTFontGetAscent(font) / scale);
        *outLineHeight = (float)((CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) / scale);
    }
}

float forge_mac_measure_text_width(const char* text, size_t len, float fontSize) {
    if (!text || len == 0) return 0.0f;
    @autoreleasepool {
        CGFloat scale = ForgeBackingScale();
        CTFontRef font = ForgeGetFont(fontSize * scale);
        if (!font) return 0.0f;

        NSString *nsText = [[NSString alloc] initWithBytes:text length:len encoding:NSUTF8StringEncoding];
        if (!nsText) return 0.0f;
        NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)font };
        NSAttributedString *attrString = [[NSAttributedString alloc] initWithString:nsText attributes:attributes];
        CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)attrString);
        double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
        CFRelease(line);
        return (float)(width / scale);
    }
}

void forge_mac_draw_text(const char* text, float x, float y, float fontSize, float r, float g, float b, float a) {
    if (!g_renderer || !g_renderer.currentEncoder) return;
    @autoreleasepool {
        CGFloat scale = ForgeBackingScale();

        NSString *nsText = [NSString stringWithUTF8String:text];
        if (nsText.length == 0) return;

        CTFontRef font = ForgeGetFont(fontSize * scale);
        if (!font) return;

        NSArray<NSString*> *lines = [nsText componentsSeparatedByString:@"\n"];
        float currentY = y;
        float lineHeight = ForgeLineHeightForFont(fontSize);
        vector_float4 color = {r, g, b, a};

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
            ForgeDrawGlyphsFromCTLine(line, font, x, currentY, scale, color);
            CFRelease(line);
            currentY += lineHeight;
        }
    }
}

void forge_mac_draw_styled_text(const char* text, size_t len, float x, float y, float fontSize,
    const ForgeTextSpan* spans, size_t span_count) {
    if (!g_renderer || !g_renderer.currentEncoder || !text || len == 0 || !spans || span_count == 0) return;
    @autoreleasepool {
        CGFloat scale = ForgeBackingScale();
        CTFontRef font = ForgeGetFont(fontSize * scale);
        if (!font) return;

        NSMutableAttributedString *attrString = [[NSMutableAttributedString alloc] init];

        for (size_t i = 0; i < span_count; i++) {
            ForgeTextSpan span = spans[i];
            if (span.length == 0 || span.offset >= len) continue;
            if (span.offset + span.length > len) continue;

            NSString *piece = [[NSString alloc] initWithBytes:(text + span.offset)
                                                       length:span.length
                                                     encoding:NSUTF8StringEncoding];
            if (!piece || piece.length == 0) continue;

            CGColorRef cgColor = CGColorCreateGenericRGB(span.r, span.g, span.b, span.a);
            NSDictionary *pieceAttrs = @{
                (id)kCTFontAttributeName: (__bridge id)font,
                (id)kCTForegroundColorAttributeName: (__bridge id)cgColor,
            };
            NSAttributedString *attrPiece = [[NSAttributedString alloc] initWithString:piece attributes:pieceAttrs];
            [attrString appendAttributedString:attrPiece];
            CGColorRelease(cgColor);
        }

        if (attrString.length == 0) return;

        CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)attrString);
        vector_float4 fallback = {1, 1, 1, 1};
        ForgeDrawGlyphsFromCTLine(line, font, x, y, scale, fallback);
        CFRelease(line);
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

void forge_mac_set_clipboard_text(const char* text, size_t len) {
    if (!text || len == 0) return;
    @autoreleasepool {
        NSData *data = [NSData dataWithBytes:text length:len];
        if (!data) return;
        NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!value) {
            value = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        }
        if (!value) return;
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        [pasteboard setString:value forType:NSPasteboardTypeString];
    }
}
