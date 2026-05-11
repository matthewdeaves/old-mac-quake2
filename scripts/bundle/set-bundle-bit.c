/* set-bundle-bit.c - set the HFS+ kHasBundle Finder flag on a .app dir.
 *
 * Why: Tiger / Panther Finder treats a `.app` directory as a package
 * (single-icon, double-clickable bundle) only when its kHasBundle bit
 * is set. Apple's `SetFile -a B` does this, but SetFile is part of
 * Xcode developer tools, which are NOT installed on our retro fleet
 * (yosemite/sawtooth/quicksilver/mini-g4). Without the bit, Finder
 * shows a generic folder icon even though Info.plist + .icns are
 * perfectly valid.
 *
 * Python ctypes-based fallbacks don't work either: Panther's Python 2.3
 * lacks ctypes (added in 2.5), and Tiger's Python 2.3 Carbon binding
 * doesn't expose finderInfo on FSCatalogInfo.
 *
 * So we compile a tiny universal binary (ppc750 + ppc7400 + x86_64) on
 * the Lion cross-build host and ship it to every PPC machine in the
 * deploy pipeline.
 *
 * Build:   clang -arch ppc -isysroot /Developer/SDKs/MacOSX10.4u.sdk
 *                  -arch x86_64 -mmacosx-version-min=10.4
 *                  set-bundle-bit.c -o set-bundle-bit
 *                  -framework CoreServices
 * Usage:   ./set-bundle-bit <path-to-.app>
 *
 * Exit codes: 0 ok / already set; non-zero on any FSRef / Catalog
 * call failure (the actual OSStatus printed to stderr).
 */

#include <CoreServices/CoreServices.h>
#include <stdio.h>
#include <string.h>

#define KHASBUNDLE 0x2000  /* DInfo.frFlags bit */

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <path-to-.app>\n", argv[0]);
        return 2;
    }

    FSRef ref;
    OSStatus err;

    err = FSPathMakeRef((const UInt8 *)argv[1], &ref, NULL);
    if (err != noErr) {
        fprintf(stderr, "FSPathMakeRef(%s): err=%d\n", argv[1], (int)err);
        return 3;
    }

    FSCatalogInfo info;
    err = FSGetCatalogInfo(&ref, kFSCatInfoFinderInfo, &info, NULL, NULL, NULL);
    if (err != noErr) {
        fprintf(stderr, "FSGetCatalogInfo: err=%d\n", (int)err);
        return 4;
    }

    /* For a directory, finderInfo is laid out as DInfo (16 bytes):
     *   frRect (8) + frFlags (2) + frLocation (4) + frView (2).
     * frFlags lives at offset 8..9. The bit at 0x2000 is kHasBundle,
     * same position as files' FInfo. The struct is big-endian on disk
     * but the Carbon API hands us host-endian, so we treat the field
     * as a UInt16. */
    UInt16 *flags = (UInt16 *)&info.finderInfo[8];
    if (*flags & KHASBUNDLE) {
        printf("kHasBundle already set on %s\n", argv[1]);
        return 0;
    }
    *flags |= KHASBUNDLE;

    err = FSSetCatalogInfo(&ref, kFSCatInfoFinderInfo, &info);
    if (err != noErr) {
        fprintf(stderr, "FSSetCatalogInfo: err=%d\n", (int)err);
        return 5;
    }

    printf("kHasBundle SET on %s\n", argv[1]);
    return 0;
}
