#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
static void (*original)(id,SEL,NSNotification *);
static void filtered(id self,SEL cmd,NSNotification *note) {
 if ([[note name] isEqualToString:NSWindowDidUpdateNotification]) return;
 original(self,cmd,note);
}
__attribute__((constructor)) static void init(void) {
 Method m=class_getInstanceMethod(objc_getClass("SDLMain"),sel_registerName("windowDidChange:"));
 if(m) original=(void*)method_setImplementation(m,(IMP)filtered);
}
