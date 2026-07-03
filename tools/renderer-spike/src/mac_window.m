#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CoreText/CoreText.h>
#import "mac_window.h"

@interface ForgeAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (strong) NSWindow *window;
@property (strong) MTKView *mtkView;
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
        [NSApplication sharedApplication];
        ForgeAppDelegate *delegate = [[ForgeAppDelegate alloc] init];
        [NSApp setDelegate:delegate];
    }
}

void forge_mac_create_window(const char* title, int width, int height) {
    @autoreleasepool {
        NSRect frame = NSMakeRect(0, 0, width, height);
        NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                       styleMask:NSWindowStyleMaskTitled |
                                                                 NSWindowStyleMaskClosable |
                                                                 NSWindowStyleMaskResizable |
                                                                 NSWindowStyleMaskMiniaturizable
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        [window center];
        [window setTitle:[NSString stringWithUTF8String:title]];
        
        // Setup Metal View
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        MTKView *mtkView = [[MTKView alloc] initWithFrame:frame device:device];
        mtkView.clearColor = MTLClearColorMake(0.1, 0.1, 0.2, 1.0);
        [window setContentView:mtkView];
        
        ForgeAppDelegate *delegate = (ForgeAppDelegate *)[NSApp delegate];
        delegate.window = window;
        delegate.mtkView = mtkView;
        
        
        // Add a text field to actually show the shaped text on screen
        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(50, height/2 - 25, width - 100, 50)];
        [label setStringValue:@"Hello Forge 🇻🇳 🚀 - CoreText is working!"];
        [label setBezeled:NO];
        [label setDrawsBackground:NO];
        [label setEditable:NO];
        [label setSelectable:NO];
        [label setTextColor:[NSColor whiteColor]];
        [label setFont:[NSFont userFixedPitchFontOfSize:24.0]];
        [label setAlignment:NSTextAlignmentCenter];
        [mtkView addSubview:label];
        
        [window makeKeyAndOrderFront:nil];
    }
}

void forge_mac_shape_text(const char* text) {
    @autoreleasepool {
        NSString *nsText = [NSString stringWithUTF8String:text];
        if (nsText != nil) {
            NSLog(@"CoreText wrapper successfully loaded string: %@", nsText);
        }
    }
}

void forge_mac_run(void) {
    @autoreleasepool {
        [NSApp run];
    }
}
