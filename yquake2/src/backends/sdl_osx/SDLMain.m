/*   SDLMain.m - main entry point for our Cocoa-ized SDL app
 Initial Version: Darrell Walisser <dwaliss1@purdue.edu>
 Non-NIB-Code & other changes: Max Horn <max@quendi.de>
 
 Feel free to customize this file to suit your needs
 */

#import <SDL/SDL.h>
#import "SDLMain.h"
#import <Carbon/Carbon.h>	/* GetCurrentKeyModifiers for the Option-key gate */
#import <sys/param.h> /* for MAXPATHLEN */
#import <unistd.h>
#include <sys/sysctl.h>	/* hw.model for the settings GUI */
#include <math.h>
//#import <iostream>

/* For some reaon, Apple removed setAppleMenu from the headers in 10.4,
 but the method still is there and works. To avoid warnings, we declare
 it ourselves here. */
@interface NSApplication(SDL_Missing_Methods)
- (void)setAppleMenu:(NSMenu *)menu;
@end

/* Use this flag to determine whether we use SDLMain.nib or not */
#define		SDL_USE_NIB_FILE	0

/* Use this flag to determine whether we use CPS (docking) or not */
#define		SDL_USE_CPS		1
#ifdef SDL_USE_CPS
/* Portions of CPS.h */
typedef struct CPSProcessSerNum
{
	UInt32		lo;
	UInt32		hi;
} CPSProcessSerNum;

extern OSErr	CPSGetCurrentProcess( CPSProcessSerNum *psn);
extern OSErr 	CPSEnableForegroundOperation( CPSProcessSerNum *psn, UInt32 _arg2, UInt32 _arg3, UInt32 _arg4, UInt32 _arg5);
extern OSErr	CPSSetFrontProcess( CPSProcessSerNum *psn);

#endif /* SDL_USE_CPS */

static int    gArgc;
static char  **gArgv;
static BOOL   gFinderLaunch;
static BOOL   gCalledAppMainline = FALSE;
/* YES once SDL_main (the engine event loop) has actually been entered. While
   the Option-gated settings window is showing, SDL_main hasn't started, so the
   menu Quit must really exit rather than push an SDL_QUIT nobody consumes. */
static BOOL   gSDLMainStarted = NO;

static NSString *getApplicationName(void)
{
    NSDictionary *dict;
    NSString *appName = 0;
	
    /* Determine the application name */
    dict = (NSDictionary *)CFBundleGetInfoDictionary(CFBundleGetMainBundle());
    if (dict)
        appName = [dict objectForKey: @"CFBundleName"];
    
    if (![appName length])
        appName = [[NSProcessInfo processInfo] processName];
	
    return appName;
}

#if SDL_USE_NIB_FILE
/* A helper category for NSString */
@interface NSString (ReplaceSubString)
- (NSString *)stringByReplacingRange:(NSRange)aRange with:(NSString *)aString;
@end
#endif

@interface SDLApplication : NSApplication
@end

@implementation SDLApplication
/* Invoked from the Quit menu item */
- (void)terminate:(id)sender
{
    /* If the engine isn't running yet (the Option-gated settings window is
       up), there's no SDL event loop to consume an SDL_QUIT -- really quit. */
    if (!gSDLMainStarted)
        exit(0);

    /* Post a SDL_QUIT event */
    SDL_Event event;
    event.type = SDL_QUIT;
    SDL_PushEvent(&event);
}
@end

/* ======================================================================
 * Settings GUI (Option-gated) -- Quake II port of the QuakeSpasm launcher.
 *
 * A plain double-click goes straight into the game (the per-machine autoexec
 * drives the tuned settings). Holding Option at startup (or passing
 * -launcher) shows this window: NSBox-grouped, typed controls preset from the
 * bundle's autoexec-<arch>+<machine>.cfg for this machine, with tooltips.
 * Changed values become `+set cvar value` overrides prepended... appended to
 * argv before SDL_main; a "Run Benchmark" button also appends +sysreport.
 * ====================================================================== */
typedef enum { Q2T_CHECK, Q2T_SLIDER, Q2T_POPUP } q2type_t;
typedef struct { const char *display; const char *value; } q2opt_t;
typedef struct {
    const char *cvar; const char *label; const char *tip;
    q2type_t type; double vmin, vmax; int isint; const q2opt_t *opts;
} q2item_t;
typedef struct { const char *title; const q2item_t *items; } q2section_t;

static const q2opt_t q2_texmode[] = {
    {"Smooth (trilinear)","GL_LINEAR_MIPMAP_LINEAR"},
    {"Bilinear","GL_LINEAR_MIPMAP_NEAREST"},
    {"Sharp / classic (nearest)","GL_NEAREST_MIPMAP_NEAREST"},
    {NULL,NULL}
};
static const q2opt_t q2_aniso[] = {
    {"Off (1x)","1"},{"2x","2"},{"4x","4"},{"8x","8"},{"16x","16"},{NULL,NULL}
};
static const q2opt_t q2_msaa[] = {
    {"Off","0"},{"2x","2"},{"4x","4"},{"8x","8"},{NULL,NULL}
};

static const q2item_t q2_sec_tex[] = {
    {"gl_picmip","Texture detail","0 = full detail; higher numbers blur textures to save memory/speed.",Q2T_SLIDER,0,4,1,NULL},
    {"gl_texturemode","Texture filter","Trilinear is smoothest; Nearest is the crisp retro look.",Q2T_POPUP,0,0,0,q2_texmode},
    {"gl_anisotropic","Anisotropic filtering","Sharpens textures at steep angles. Higher is sharper for a small GPU cost.",Q2T_POPUP,0,0,0,q2_aniso},
    {"gl_msaa_samples","Anti-aliasing (MSAA)","Smooths jagged edges. Higher costs more GPU.",Q2T_POPUP,0,0,0,q2_msaa},
    {"gl_retexturing","HD texture pack","Use the bundled high-resolution texture pack when available.",Q2T_CHECK,0,0,0,NULL},
    {NULL}
};
static const q2item_t q2_sec_light[] = {
    {"gl_dynamic","Dynamic lighting","Lights from rockets, explosions, etc.",Q2T_CHECK,0,0,0,NULL},
    {"gl_flashblend","Fast blended lights","Cheap blended light blobs instead of true dynamic lighting.",Q2T_CHECK,0,0,0,NULL},
    {"gl_shadows","Entity shadows","Blob shadows under models.",Q2T_CHECK,0,0,0,NULL},
    {"gl_stencilshadow","Stencil shadows","Sharper stencil-based shadows (costs more).",Q2T_CHECK,0,0,0,NULL},
    {"gl_glows","Glow effects","Glowing surfaces / items.",Q2T_CHECK,0,0,0,NULL},
    {"gl_trans_lighting","Lit transparent surfaces","Apply lighting to translucent surfaces.",Q2T_CHECK,0,0,0,NULL},
    {NULL}
};
static const q2item_t q2_sec_fx[] = {
    {"gl_caustics","Underwater caustics","Rippling light patterns underwater.",Q2T_CHECK,0,0,0,NULL},
    {"gl_bloom","Bloom","Soft glow around bright areas.",Q2T_CHECK,0,0,0,NULL},
    {"gl_fog","Fog","Volumetric fog where maps define it.",Q2T_CHECK,0,0,0,NULL},
    {"gl_waterwarp","Water warp","Screen warble while underwater.",Q2T_CHECK,0,0,0,NULL},
    {"gl_decals","Decals","Bullet/blast marks on surfaces.",Q2T_CHECK,0,0,0,NULL},
    {"gl_decal_max","Max decals","How many decals persist at once.",Q2T_SLIDER,0,512,1,NULL},
    {NULL}
};
static const q2item_t q2_sec_perf[] = {
    {"cl_maxfps","Max FPS","Frame-rate cap.",Q2T_SLIDER,30,250,1,NULL},
    {"gl_swapinterval","VSync","Sync to display refresh (off can raise fps, may tear).",Q2T_CHECK,0,0,0,NULL},
    {"gl_finish","GL finish each frame","Forces the GPU to finish each frame (usually off).",Q2T_CHECK,0,0,0,NULL},
    {"gl_clear","Clear screen each frame","Usually off (faster).",Q2T_CHECK,0,0,0,NULL},
    {NULL}
};
static const q2section_t q2_sections[] = {
    {"Textures", q2_sec_tex},
    {"Lighting & shadows", q2_sec_light},
    {"Effects", q2_sec_fx},
    {"Performance", q2_sec_perf},
    {NULL,NULL}
};

/* resolution presets (Default = let the per-machine cfg decide) */
static const q2opt_t q2_resos[] = {
    {"Default (per-machine)",""}, {"800 x 600","800x600"}, {"1024 x 768","1024x768"},
    {"1280 x 1024","1280x1024"}, {"1440 x 900","1440x900"}, {"1680 x 1050","1680x1050"},
    {NULL,NULL}
};

@interface Q2FlippedView : NSView
@end
@implementation Q2FlippedView
- (BOOL)isFlipped { return YES; }
@end

static BOOL Q2_ShouldShowLauncher(void);

@interface Q2Settings : NSObject {
    NSWindow *window;
    NSPopUpButton *resPopup;
    NSButton *fullscreenCheck;
    NSMutableArray *controls;
    NSMutableArray *readouts;
    NSMutableArray *origValues;
    NSMutableArray *items;
    NSMutableDictionary *cfgDefaults;
}
+ (void)showLauncher;
- (void)build;
- (IBAction)sliderChanged:(id)sender;
- (IBAction)doLaunch:(id)sender;
- (IBAction)doBenchmark:(id)sender;
- (IBAction)doQuit:(id)sender;
@end

/* The main class of the application, the application's delegate */
@implementation SDLMain

/* Set the working directory to the .app's parent directory */
- (void) setupWorkingDirectory:(BOOL)shouldChdir
{
	printf("setting up working dir\n");
    if (shouldChdir)
    {
    	printf("chdir...\n");
#if defined(USE_APP_RESOURCES)
		CFBundleRef mainBundle = CFBundleGetMainBundle();
		CFURLRef resourcesURL = CFBundleCopyResourcesDirectoryURL(mainBundle);
		char path[MAXPATHLEN];
		if (CFURLGetFileSystemRepresentation(resourcesURL, true, (UInt8 *)path, MAXPATHLEN)) {
			assert ( chdir (path) == 0 ); /* chdir to the Resources directory of app */
		}
		printf("Path: %s\n", path);
		CFRelease(resourcesURL);
#else
        char parentdir[MAXPATHLEN];
		CFURLRef url = CFBundleCopyBundleURL(CFBundleGetMainBundle());
		CFURLRef url2 = CFURLCreateCopyDeletingLastPathComponent(0, url);
		if (CFURLGetFileSystemRepresentation(url2, true, (UInt8 *)parentdir, MAXPATHLEN)) {
	        assert ( chdir (parentdir) == 0 );   /* chdir to the binary app's parent */
		}
		CFRelease(url);
		CFRelease(url2);
#endif
	}
	
}

#if SDL_USE_NIB_FILE

/* Fix menu to contain the real app name instead of "SDL App" */
- (void)fixMenu:(NSMenu *)aMenu withAppName:(NSString *)appName
{
    NSRange aRange;
    NSEnumerator *enumerator;
    NSMenuItem *menuItem;
	
    aRange = [[aMenu title] rangeOfString:@"SDL App"];
    if (aRange.length != 0)
        [aMenu setTitle: [[aMenu title] stringByReplacingRange:aRange with:appName]];
	
    enumerator = [[aMenu itemArray] objectEnumerator];
    while ((menuItem = [enumerator nextObject]))
    {
        aRange = [[menuItem title] rangeOfString:@"SDL App"];
        if (aRange.length != 0)
            [menuItem setTitle: [[menuItem title] stringByReplacingRange:aRange with:appName]];
        if ([menuItem hasSubmenu])
            [self fixMenu:[menuItem submenu] withAppName:appName];
    }
    [ aMenu sizeToFit ];
}

#else

static void setApplicationMenu(void)
{
    /* warning: this code is very odd */
    NSMenu *appleMenu;
    NSMenuItem *menuItem;
    NSString *title;
    NSString *appName;
    
    appName = getApplicationName();
    appleMenu = [[NSMenu alloc] initWithTitle:@""];
    
    /* Add menu items */
    title = [@"About " stringByAppendingString:appName];
    [appleMenu addItemWithTitle:title action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
	
    [appleMenu addItem:[NSMenuItem separatorItem]];
	
    title = [@"Hide " stringByAppendingString:appName];
    [appleMenu addItemWithTitle:title action:@selector(hide:) keyEquivalent:@"h"];
	
    menuItem = (NSMenuItem *)[appleMenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    [menuItem setKeyEquivalentModifierMask:(NSAlternateKeyMask|NSCommandKeyMask)];
	
    [appleMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
	
    [appleMenu addItem:[NSMenuItem separatorItem]];
	
    title = [@"Quit " stringByAppendingString:appName];
    [appleMenu addItemWithTitle:title action:@selector(terminate:) keyEquivalent:@"q"];
	
    
    /* Put menu into the menubar */
    menuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [menuItem setSubmenu:appleMenu];
    [[NSApp mainMenu] addItem:menuItem];
	
    /* Tell the application object that this is now the application menu */
    [NSApp setAppleMenu:appleMenu];
	
    /* Finally give up our references to the objects */
    [appleMenu release];
    [menuItem release];
}

/* Create a window menu */
static void setupWindowMenu(void)
{
    NSMenu      *windowMenu;
    NSMenuItem  *windowMenuItem;
    NSMenuItem  *menuItem;
	
    windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    
    /* "Minimize" item */
    menuItem = [[NSMenuItem alloc] initWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItem:menuItem];
    [menuItem release];
    
    /* Put menu into the menubar */
    windowMenuItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""];
    [windowMenuItem setSubmenu:windowMenu];
    [[NSApp mainMenu] addItem:windowMenuItem];
    
    /* Tell the application object that this is now the window menu */
    [NSApp setWindowsMenu:windowMenu];
	
    /* Finally give up our references to the objects */
    [windowMenu release];
    [windowMenuItem release];
}

/* Replacement for NSApplicationMain */
static void CustomApplicationMain (int argc, char **argv)
{
    NSAutoreleasePool	*pool = [[NSAutoreleasePool alloc] init];
    SDLMain				*sdlMain;
	
    /* Ensure the application object is initialised */
    [SDLApplication sharedApplication];
    
#ifdef SDL_USE_CPS
    {
        CPSProcessSerNum PSN;
        /* Tell the dock about us */
        if (!CPSGetCurrentProcess(&PSN))
            if (!CPSEnableForegroundOperation(&PSN,0x03,0x3C,0x2C,0x1103))
                if (!CPSSetFrontProcess(&PSN))
                    [SDLApplication sharedApplication];
    }
#endif /* SDL_USE_CPS */
	
    /* Set up the menubar */
    [NSApp setMainMenu:[[NSMenu alloc] init]];
    setApplicationMenu();
    setupWindowMenu();
	
    /* Create SDLMain and make it the app delegate */
    sdlMain = [[SDLMain alloc] init];
    [NSApp setDelegate:sdlMain];
    
    /* Start the main event loop */
    [NSApp run];
    
    [sdlMain release];
    [pool release];
}

#endif


/*
 * Catch document open requests...this lets us notice files when the app
 *  was launched by double-clicking a document, or when a document was
 *  dragged/dropped on the app's icon. You need to have a
 *  CFBundleDocumentsType section in your Info.plist to get this message,
 *  apparently.
 *
 * Files are added to gArgv, so to the app, they'll look like command line
 *  arguments. Previously, apps launched from the finder had nothing but
 *  an argv[0].
 *
 * This message may be received multiple times to open several docs on launch.
 *
 * This message is ignored once the app's mainline has been called.
 */
- (BOOL)application:(NSApplication *)theApplication openFile:(NSString *)filename
{
    const char *temparg;
    size_t arglen;
    char *arg;
    char **newargv;
	
    if (!gFinderLaunch)  /* MacOS is passing command line args. */
        return FALSE;
	
    if (gCalledAppMainline)  /* app has started, ignore this document. */
        return FALSE;
	
    temparg = [filename UTF8String];
    arglen = SDL_strlen(temparg) + 1;
    arg = (char *) SDL_malloc(arglen);
    if (arg == NULL)
        return FALSE;
	
    newargv = (char **) realloc(gArgv, sizeof (char *) * (gArgc + 2));
    if (newargv == NULL)
    {
        SDL_free(arg);
        return FALSE;
    }
    gArgv = newargv;
	
    SDL_strlcpy(arg, temparg, arglen);
    gArgv[gArgc++] = arg;
    gArgv[gArgc] = NULL;
    return TRUE;
}


/* Called when the internal event loop has just started running */
- (void) applicationDidFinishLaunching: (NSNotification *) note
{
    int status;
	
    /* Set the working directory to the .app's parent directory */
    [self setupWorkingDirectory:gFinderLaunch];
	
#if SDL_USE_NIB_FILE
    /* Set the main menu to contain the real app name instead of "SDL App" */
    [self fixMenu:[NSApp mainMenu] withAppName:getApplicationName()];
#endif
	
    /* Hand off to main application code */
    gCalledAppMainline = TRUE;

    /* Option-key gate: show the settings GUI only when Option is held at
       startup (or -launcher is passed). Otherwise go straight into the game
       so the per-machine autoexec drives the already-tuned settings. */
    if (Q2_ShouldShowLauncher())
    {
        [Q2Settings showLauncher];
        return; /* the settings controller calls SDL_main on Launch */
    }

    gSDLMainStarted = YES;
    status = SDL_main (gArgc, gArgv);
	
    /* We're done, thank you for playing */
    exit(status);
}
@end


/* ====================================================================== */
/* Settings GUI implementation                                            */
/* ====================================================================== */

/* Decide whether to show the launcher, and strip -launcher/-nolauncher from
   gArgv so they never reach the engine. */
static BOOL Q2_ShouldShowLauncher(void)
{
    BOOL forceLauncher = NO, forceNo = NO;
    int r, w;

    for (r = 1; r < gArgc; r++)
    {
        if (!strcmp(gArgv[r], "-launcher")) forceLauncher = YES;
        else if (!strcmp(gArgv[r], "-nolauncher")) forceNo = YES;
    }
    for (w = 1, r = 1; r < gArgc; r++)
    {
        if (!strcmp(gArgv[r], "-launcher") || !strcmp(gArgv[r], "-nolauncher"))
            continue;
        gArgv[w++] = gArgv[r];
    }
    gArgc = w;
    gArgv[gArgc] = NULL;

    if (forceNo)
        return NO;
    if (forceLauncher)
        return YES;
    return (GetCurrentKeyModifiers() & optionKey) != 0;
}

@implementation Q2Settings

+ (void)showLauncher
{
    Q2Settings *c = [[Q2Settings alloc] init];
    [c build];
    /* intentionally never released: it owns the window until SDL_main/exit */
}

- (NSString *)machineConfigName
{
    static const struct { const char *model; const char *cfg; } map[] = {
        {"PowerMac1,1","autoexec-yosemite"}, {"PowerMac3,1","autoexec-sawtooth"},
        {"PowerMac3,5","autoexec-quicksilver"}, {"PowerMac10,1","autoexec-mini-g4"},
        {"PowerMac8,2","autoexec-imac-g5"}, {"Macmini2,1","autoexec-mini-intel"},
        {"iMac19,1","autoexec-imac-2019"},
    };
    char model[64];
    size_t mlen, i;

    mlen = sizeof(model);
    memset(model, 0, sizeof(model));
    if (sysctlbyname("hw.model", model, &mlen, NULL, 0) != 0 || model[0] == 0)
        return nil;
    for (i = 0; i < sizeof(map)/sizeof(map[0]); i++)
        if (!strcmp(model, map[i].model))
            return [NSString stringWithUTF8String:map[i].cfg];
    return nil;
}

/* parse `set CVAR VALUE` lines from a bundled cfg (later files win) */
- (void)parseConfig:(NSString *)basename into:(NSMutableDictionary *)dict
{
    NSString *path, *contents;
    NSCharacterSet *ws;
    NSArray *lines;
    int li;

    if (basename == nil)
        return;
    path = [[NSBundle mainBundle] pathForResource:basename ofType:@"cfg"];
    if (path == nil)
        return;
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1040
    contents = [NSString stringWithContentsOfFile:path];
#else
    contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
#endif
    if (contents == nil)
        return;

    ws = [NSCharacterSet whitespaceCharacterSet];
    lines = [contents componentsSeparatedByString:@"\n"];
    for (li = 0; li < (int)[lines count]; li++)
    {
        NSString *line, *tok, *key, *val;
        NSScanner *sc;

        line = [[lines objectAtIndex:li] stringByTrimmingCharactersInSet:ws];
        if ([line length] == 0 || [line hasPrefix:@"//"])
            continue;
        sc = [NSScanner scannerWithString:line];
        tok = nil; key = nil; val = nil;
        if (![sc scanUpToCharactersFromSet:ws intoString:&tok])
            continue;
        if (![tok isEqualToString:@"set"])
            continue;  /* cfgs are `set CVAR VALUE` */
        if (![sc scanUpToCharactersFromSet:ws intoString:&key])
            continue;
        if (![sc scanUpToCharactersFromSet:ws intoString:&val])
            continue;
        if ([val length] >= 2 && [val hasPrefix:@"\""] && [val hasSuffix:@"\""])
            val = [val substringWithRange:NSMakeRange(1, [val length]-2)];
        [dict setObject:val forKey:key];
    }
}

- (void)loadDefaults
{
#if defined(Q2_ARCH_PPC970)
    NSString *archCfg = @"autoexec-ppc970";
#elif defined(__VEC__) || defined(__ALTIVEC__)
    NSString *archCfg = @"autoexec-ppc7400";
#elif defined(__ppc__) || defined(__POWERPC__) || defined(__powerpc__)
    NSString *archCfg = @"autoexec-ppc750";
#elif defined(__x86_64__) || defined(__amd64__)
    NSString *archCfg = @"autoexec-x86_64";
#else
    NSString *archCfg = nil;
#endif
    cfgDefaults = [[NSMutableDictionary alloc] init];
    [self parseConfig:archCfg into:cfgDefaults];
    [self parseConfig:[self machineConfigName] into:cfgDefaults];
}

- (NSString *)valueForCvar:(const char *)cvar
{
    return [cfgDefaults objectForKey:[NSString stringWithUTF8String:cvar]];
}

- (NSTextField *)label:(NSString *)s frame:(NSRect)f align:(NSTextAlignment)al
{
    NSTextField *t = [[NSTextField alloc] initWithFrame:f];
    [t setStringValue:s];
    [t setEditable:NO]; [t setSelectable:NO]; [t setBordered:NO];
    [t setBezeled:NO]; [t setDrawsBackground:NO]; [t setAlignment:al];
    [[t cell] setFont:[NSFont systemFontOfSize:11]];
    return [t autorelease];
}

- (void)build
{
    /* C89 declarations -- the Panther gcc-4.0 ObjC compile is strict and
       has no CGFloat (10.5+), so declare everything up front and use float. */
    float W, boxX, boxW, rowH, topPad, botPad, gap, y;
    float docHeight, barH, visibleDoc, winW, winH;
    int idx, s;
    Q2FlippedView *doc;
    char mdl[64];
    size_t ml;
    NSString *modelStr;
    NSView *content;
    NSScrollView *scroll;
    NSButton *quit, *bench, *play;

    [self loadDefaults];
    controls   = [[NSMutableArray alloc] init];
    readouts   = [[NSMutableArray alloc] init];
    origValues = [[NSMutableArray alloc] init];
    items      = [[NSMutableArray alloc] init];

    W = 540; boxX = 12; boxW = W - 24;
    rowH = 28; topPad = 26; botPad = 12; gap = 14;
    y = 10; idx = 0;

    doc = [[Q2FlippedView alloc] initWithFrame:NSMakeRect(0,0,W,4000)];

    ml = sizeof(mdl); mdl[0] = 0;
    sysctlbyname("hw.model", mdl, &ml, NULL, 0);
    modelStr = (mdl[0]) ? [NSString stringWithUTF8String:mdl] : @"this machine";
    [doc addSubview:[self label:[NSString stringWithFormat:
        @"Defaults are tuned for %@ - tweak below, then Launch. Hover any control for a tip.", modelStr]
        frame:NSMakeRect(boxX, y, boxW, 18) align:NSLeftTextAlignment]];
    y += 26;

    /* Display box */
    {
        float boxH, r0;
        NSBox *box;
        int oi;
        NSString *fs;
        BOOL fsOn;

        boxH = topPad + 2*rowH + botPad;
        r0 = y + topPad;
        box = [[NSBox alloc] initWithFrame:NSMakeRect(boxX,y,boxW,boxH)];
        [box setTitle:@"Display"]; [box setTitlePosition:NSAtTop];
        [doc addSubview:box];
        [doc addSubview:[self label:@"Resolution" frame:NSMakeRect(boxX+16,r0+3,170,18) align:NSLeftTextAlignment]];
        resPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(boxX+196,r0-2,296,24) pullsDown:NO];
        for (oi = 0; q2_resos[oi].display != NULL; oi++)
            [resPopup addItemWithTitle:[NSString stringWithUTF8String:q2_resos[oi].display]];
        [resPopup setToolTip:@"Display resolution. 'Default' lets the per-machine config decide."];
        [doc addSubview:resPopup];

        fullscreenCheck = [[NSButton alloc] initWithFrame:NSMakeRect(boxX+16,r0+rowH,boxW-40,20)];
        [fullscreenCheck setButtonType:NSSwitchButton];
        [fullscreenCheck setTitle:@"Fullscreen"];
        [[fullscreenCheck cell] setFont:[NSFont systemFontOfSize:11]];
        /* default fullscreen ON unless the cfg explicitly says 0 */
        fs = [self valueForCvar:"vid_fullscreen"];
        fsOn = (fs == nil) || ([fs doubleValue] != 0.0);
        [fullscreenCheck setState:fsOn ? NSOnState : NSOffState];
        [fullscreenCheck setToolTip:@"Run fullscreen (recommended) or in a window."];
        [doc addSubview:fullscreenCheck];
        [box release];
        y += boxH + gap;
    }

    for (s = 0; q2_sections[s].title != NULL; s++)
    {
        const q2section_t *sec;
        int nrows, r;
        float boxH;
        NSBox *box;

        sec = &q2_sections[s];
        nrows = 0;
        while (sec->items[nrows].cvar != NULL) nrows++;

        boxH = topPad + nrows*rowH + botPad;
        box = [[NSBox alloc] initWithFrame:NSMakeRect(boxX,y,boxW,boxH)];
        [box setTitle:[NSString stringWithUTF8String:sec->title]];
        [box setTitlePosition:NSAtTop];
        [doc addSubview:box];

        for (r = 0; r < nrows; r++)
        {
            const q2item_t *item;
            float ry;
            NSString *cur, *tip, *lab;

            item = &sec->items[r];
            ry = y + topPad + r*rowH;
            cur = [self valueForCvar:item->cvar];
            tip = [NSString stringWithUTF8String:item->tip];
            lab = [NSString stringWithUTF8String:item->label];

            if (item->type == Q2T_CHECK)
            {
                NSButton *b;
                BOOL on;

                b = [[NSButton alloc] initWithFrame:NSMakeRect(boxX+16,ry,boxW-40,20)];
                [b setButtonType:NSSwitchButton];
                [b setTitle:lab];
                [[b cell] setFont:[NSFont systemFontOfSize:11]];
                [b setToolTip:tip];
                on = (cur != nil) && ([cur doubleValue] != 0.0);
                [b setState: on ? NSOnState : NSOffState];
                [b setTag:idx];
                [doc addSubview:b];
                [controls addObject:b];
                [readouts addObject:[NSNull null]];
                [origValues addObject:(on ? @"1" : @"0")];
                [items addObject:[NSValue valueWithPointer:item]];
                [b release];
            }
            else if (item->type == Q2T_SLIDER)
            {
                NSSlider *sl;
                double v;
                NSString *rs;
                NSTextField *ro;

                v = (cur != nil) ? [cur doubleValue] : item->vmin;
                sl = [[NSSlider alloc] initWithFrame:NSMakeRect(boxX+196,ry,236,20)];
                [sl setMinValue:item->vmin]; [sl setMaxValue:item->vmax];
                [sl setDoubleValue:v];
                [sl setContinuous:YES];
                [sl setTarget:self]; [sl setAction:@selector(sliderChanged:)];
                [sl setToolTip:tip]; [sl setTag:idx];
                rs = item->isint ? [NSString stringWithFormat:@"%d",(int)(v+0.5)]
                                 : [NSString stringWithFormat:@"%.2f",v];
                ro = [self label:rs frame:NSMakeRect(boxX+438,ry+1,60,18) align:NSRightTextAlignment];
                [doc addSubview:[self label:lab frame:NSMakeRect(boxX+16,ry+1,176,18) align:NSLeftTextAlignment]];
                [doc addSubview:sl];
                [doc addSubview:ro];
                [controls addObject:sl];
                [readouts addObject:ro];
                [origValues addObject:rs];
                [items addObject:[NSValue valueWithPointer:item]];
                [sl release];
            }
            else /* Q2T_POPUP */
            {
                NSPopUpButton *p;
                int oi2, sel;
                NSString *resolved;

                sel = -1;
                resolved = nil;
                p = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(boxX+196,ry-2,260,24) pullsDown:NO];
                [p setToolTip:tip]; [p setTag:idx];
                for (oi2 = 0; item->opts[oi2].display != NULL; oi2++)
                {
                    [p addItemWithTitle:[NSString stringWithUTF8String:item->opts[oi2].display]];
                    if (cur != nil && strcmp(item->opts[oi2].value, [cur UTF8String]) == 0)
                    {
                        sel = oi2;
                        resolved = [NSString stringWithUTF8String:item->opts[oi2].value];
                    }
                }
                if (sel < 0)
                {
                    if (cur != nil) { [p addItemWithTitle:cur]; sel = [p numberOfItems]-1; resolved = cur; }
                    else { sel = 0; resolved = [NSString stringWithUTF8String:item->opts[0].value]; }
                }
                [p selectItemAtIndex:sel];
                [doc addSubview:[self label:lab frame:NSMakeRect(boxX+16,ry+3,176,18) align:NSLeftTextAlignment]];
                [doc addSubview:p];
                [controls addObject:p];
                [readouts addObject:[NSNull null]];
                [origValues addObject:resolved];
                [items addObject:[NSValue valueWithPointer:item]];
                [p release];
            }
            idx++;
        }
        [box release];
        y += boxH + gap;
    }

    docHeight = y;
    [doc setFrame:NSMakeRect(0,0,W,docHeight)];

    barH = 48;
    visibleDoc = (docHeight < 520) ? docHeight : 520;
    winW = W + 18;
    winH = visibleDoc + barH;

    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,winW,winH)
        styleMask:(NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask)
        backing:NSBackingStoreBuffered defer:NO];
    [window setTitle:@"Quake II Settings"];
    [window setReleasedWhenClosed:NO];
    content = [window contentView];

    scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0,barH,winW,visibleDoc)];
    [scroll setHasVerticalScroller:YES];
    [scroll setHasHorizontalScroller:NO];
    [scroll setBorderType:NSNoBorder];
    [scroll setDocumentView:doc];
    [scroll setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [content addSubview:scroll];
    [[scroll contentView] scrollToPoint:NSMakePoint(0,0)];
    [scroll reflectScrolledClipView:[scroll contentView]];
    [scroll release];
    [doc release];

    quit = [[NSButton alloc] initWithFrame:NSMakeRect(12,10,90,28)];
    [quit setTitle:@"Quit"]; [quit setBezelStyle:NSRoundedBezelStyle];
    [quit setTarget:self]; [quit setAction:@selector(doQuit:)];
    [content addSubview:quit]; [quit release];

    bench = [[NSButton alloc] initWithFrame:NSMakeRect(winW-300,10,172,28)];
    [bench setTitle:@"Run Benchmark"]; [bench setBezelStyle:NSRoundedBezelStyle];
    [bench setToolTip:@"Run the timedemo benchmark with these settings and write a sysreport to the Desktop (silent)."];
    [bench setTarget:self]; [bench setAction:@selector(doBenchmark:)];
    [content addSubview:bench]; [bench release];

    play = [[NSButton alloc] initWithFrame:NSMakeRect(winW-122,10,110,28)];
    [play setTitle:@"Launch"]; [play setBezelStyle:NSRoundedBezelStyle];
    [play setTarget:self]; [play setAction:@selector(doLaunch:)];
    [play setKeyEquivalent:@"\r"];
    [content addSubview:play]; [play release];

    [window center];
    [window makeKeyAndOrderFront:self];
    [NSApp activateIgnoringOtherApps:YES];
}

- (IBAction)sliderChanged:(id)sender
{
    int tag;
    id ro;
    const q2item_t *item;
    double v;
    NSString *s;

    tag = [sender tag];
    ro = [readouts objectAtIndex:tag];
    if (ro == [NSNull null]) return;
    item = (const q2item_t *)[[items objectAtIndex:tag] pointerValue];
    v = [sender doubleValue];
    s = item->isint ? [NSString stringWithFormat:@"%d",(int)(v+0.5)]
                     : [NSString stringWithFormat:@"%.2f",v];
    [(NSTextField *)ro setStringValue:s];
}

/* Collect `+set cvar value` overrides for changed controls, plus resolution +
   fullscreen, into an NSMutableArray of argv tokens. */
- (NSMutableArray *)collectArgs
{
    NSMutableArray *a;
    int ri, i, n;

    a = [NSMutableArray array];

    ri = [resPopup indexOfSelectedItem];
    if (ri > 0 && q2_resos[ri].value[0])
    {
        NSString *wh = [NSString stringWithUTF8String:q2_resos[ri].value];
        NSArray *parts = [wh componentsSeparatedByString:@"x"];
        if ([parts count] == 2)
        {
            [a addObject:@"+set"]; [a addObject:@"gl_mode"]; [a addObject:@"-1"];
            [a addObject:@"+set"]; [a addObject:@"gl_customwidth"];  [a addObject:[parts objectAtIndex:0]];
            [a addObject:@"+set"]; [a addObject:@"gl_customheight"]; [a addObject:[parts objectAtIndex:1]];
        }
    }

    [a addObject:@"+set"]; [a addObject:@"vid_fullscreen"];
    [a addObject:([fullscreenCheck state] == NSOnState) ? @"1" : @"0"];

    n = [controls count];
    for (i = 0; i < n; i++)
    {
        const q2item_t *item;
        id ctl;
        NSString *orig, *cur;
        BOOL changed;

        item = (const q2item_t *)[[items objectAtIndex:i] pointerValue];
        ctl = [controls objectAtIndex:i];
        orig = [origValues objectAtIndex:i];
        cur = nil;
        changed = NO;

        if (item->type == Q2T_CHECK)
        {
            cur = ([ctl state] == NSOnState) ? @"1" : @"0";
            changed = ![cur isEqualToString:orig];
        }
        else if (item->type == Q2T_SLIDER)
        {
            double v = [ctl doubleValue];
            cur = item->isint ? [NSString stringWithFormat:@"%d",(int)(v+0.5)]
                              : [NSString stringWithFormat:@"%.2f",v];
            changed = fabs(v - [orig doubleValue]) > 0.0001;
        }
        else
        {
            NSString *title = [ctl titleOfSelectedItem];
            int oi;
            cur = title;
            for (oi = 0; item->opts[oi].display != NULL; oi++)
                if ([title isEqualToString:[NSString stringWithUTF8String:item->opts[oi].display]])
                {
                    cur = [NSString stringWithUTF8String:item->opts[oi].value];
                    break;
                }
            changed = ![cur isEqualToString:orig];
        }

        if (changed)
        {
            [a addObject:@"+set"];
            [a addObject:[NSString stringWithUTF8String:item->cvar]];
            [a addObject:cur];
        }
    }
    return a;
}

- (void)launchWithExtra:(NSArray *)extra
{
    int n, i, status;
    char **argv;

    n = gArgc + (int)[extra count];
    argv = (char **)malloc(sizeof(char *) * (n + 1));
    for (i = 0; i < gArgc; i++)
        argv[i] = gArgv[i];
    for (i = 0; i < (int)[extra count]; i++)
        argv[gArgc + i] = SDL_strdup([[extra objectAtIndex:i] UTF8String]);
    argv[n] = NULL;

    [window close];
    gSDLMainStarted = YES;
    status = SDL_main(n, argv);
    exit(status);
}

- (IBAction)doLaunch:(id)sender
{
    [self launchWithExtra:[self collectArgs]];
}

- (IBAction)doBenchmark:(id)sender
{
    NSMutableArray *a = [self collectArgs];
    /* silent benchmark + run the grid; report lands on the Desktop */
    [a addObject:@"+set"]; [a addObject:@"s_initsound"]; [a addObject:@"0"];
    [a addObject:@"+sysreport"];
    [self launchWithExtra:a];
}

- (IBAction)doQuit:(id)sender
{
    exit(0);
}

@end


@implementation NSString (ReplaceSubString)

- (NSString *)stringByReplacingRange:(NSRange)aRange with:(NSString *)aString
{
    unsigned int bufferSize;
    unsigned int selfLen = [self length];
    unsigned int aStringLen = [aString length];
    unichar *buffer;
    NSRange localRange;
    NSString *result;
	
    bufferSize = selfLen + aStringLen - aRange.length;
    buffer = NSAllocateMemoryPages(bufferSize*sizeof(unichar));
    
    /* Get first part into buffer */
    localRange.location = 0;
    localRange.length = aRange.location;
    [self getCharacters:buffer range:localRange];
    
    /* Get middle part into buffer */
    localRange.location = 0;
    localRange.length = aStringLen;
    [aString getCharacters:(buffer+aRange.location) range:localRange];
	
    /* Get last part into buffer */
    localRange.location = aRange.location + aRange.length;
    localRange.length = selfLen - localRange.location;
    [self getCharacters:(buffer+aRange.location+aStringLen) range:localRange];
    
    /* Build output string */
    result = [NSString stringWithCharacters:buffer length:bufferSize];
    
    NSDeallocateMemoryPages(buffer, bufferSize);
    
    return result;
}

@end



#ifdef main
#  undef main
#endif


/* Main entry point to executable - should *not* be SDL_main! */
int main (int argc, char **argv)
{
    /* Copy the arguments into a global variable */
    /* This is passed if we are launched by double-clicking */
    if ( argc >= 2 && strncmp (argv[1], "-psn", 4) == 0 ) {
        gArgv = (char **) SDL_malloc(sizeof (char *) * 2);
        gArgv[0] = argv[0];
        gArgv[1] = NULL;
        gArgc = 1;
        gFinderLaunch = YES;
    } else {
        int i;
        gArgc = argc;
        gArgv = (char **) SDL_malloc(sizeof (char *) * (argc+1));
        for (i = 0; i <= argc; i++)
            gArgv[i] = argv[i];
        gFinderLaunch = NO;
    }
	
#if SDL_USE_NIB_FILE
    [SDLApplication poseAsClass:[NSApplication class]];
    NSApplicationMain (argc, argv);
#else
    CustomApplicationMain (argc, argv);
#endif
    return 0;
}
