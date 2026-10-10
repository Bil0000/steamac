/* wmtr_present_test: the overlay presenter (WMTR_PRESENT=overlay) attaches the game's CAMetalLayer as a
 * sublayer of the launcher's VMView layer and detaches it on release; called from a non-main thread like
 * the executor does. Oracle: the AppKit layer tree. */
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <stdlib.h>
#include "wmtr_host.h"

@interface TestVMView : NSView
@property BOOL gameLayersVisible;
@end
@implementation TestVMView
- (CALayer *)makeBackingLayer { return [CAMetalLayer layer]; }
@end

static int failures;
#define CHECK(c, m) do { if (!(c)) { failures++; fprintf(stderr, "FAIL: %s\n", m); } } while (0)

int main(void) {
  @autoreleasepool {
    setenv("WMTR_PRESENT", "overlay", 1);
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 200) styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered defer:NO];
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 200)];
    TestVMView *vm = [[TestVMView alloc] initWithFrame:NSMakeRect(0, 0, 320, 200)];
    vm.wantsLayer = YES;
    [root addSubview:vm];
    [w setContentView:root];
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      uint64_t layer = 0;
      uint64_t view = wmtr_present_create_view(NULL, 0x1234, (void *)dev, &layer);
      dispatch_sync(dispatch_get_main_queue(), ^{
        CHECK(view == (uint64_t)vm, "returned view is not the VMView");
        CHECK(layer && [vm.layer.sublayers containsObject:(CALayer *)layer], "game layer not attached to the VMView layer");
        CHECK(layer && ((CAMetalLayer *)layer).device == dev, "layer device");
        CHECK(layer && NSEqualRects(NSRectFromCGRect(((CALayer *)layer).frame), NSRectFromCGRect(vm.layer.bounds)), "layer frame");
        CHECK(layer && ((CALayer *)layer).hidden, "game layer shown although no game has the guest's focus");
      });
      wmtr_present_release_view(NULL, view);
      dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_async(dispatch_get_main_queue(), ^{
          CHECK(![vm.layer.sublayers count], "game layer not detached");
          printf(failures ? "wmtr_present_test: %d FAILED\n" : "wmtr_present_test: all passed\n", failures);
          exit(failures != 0);
        });
      });
    });
    [NSApp run];
  }
  return 1;
}
