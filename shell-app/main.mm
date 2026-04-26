// Beads.app — entry point.
//
// Standalone macOS app that hosts the same BeadsPanel the Notepad++ plugin
// uses, in a regular NSWindow with a real Cocoa menu bar. Same source tree,
// same viewer assets, no Notepad++ dependency.

#import <Cocoa/Cocoa.h>
#import "BeadsAppDelegate.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        // Standard "regular" activation policy — dock icon, menu bar,
        // appears in Cmd-Tab. Anything else (Accessory, Prohibited) is
        // for menu-bar-only / agent processes which Beads is not.
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        BeadsAppDelegate *delegate = [[BeadsAppDelegate alloc] init];
        app.delegate = delegate;

        // Run. NSApp.run handles its own RunLoop; never returns until
        // applicationShouldTerminate gives the OK and the loop unwinds.
        [app run];
    }
    return 0;
}
