#import <Cocoa/Cocoa.h>

void NSMenu_setMenuBarVisible(int flag) {
    if (flag) {
        [NSMenu setMenuBarVisible:YES];
    } else {
        [NSMenu setMenuBarVisible:NO];
    }
}

extern int SDL_main(int argc, char **argv);

int main(int argc, char **argv) {
    @autoreleasepool {
        return SDL_main(argc, argv);
    }
}

@implementation NSWindow (KeyWindow)
- (BOOL)canBecomeKeyWindow {
    return YES;
}
@end

@implementation NSView (UpdateLayer)
- (BOOL)wantsUpdateLayer {
    return YES;
}
- (void)updateLayer {
    [[NSOpenGLContext currentContext] update];
}
@end