/*
 * Copyright (C) 1997-2001 Id Software, Inc.
 * Copyright (C) 2015 Daniel Gibson  (stb_image wrapper pattern)
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or (at
 * your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 *
 * See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
 * 02111-1307, USA.
 *
 * =======================================================================
 *
 * JPEG image loader. Originally used libjpeg; this rewrite drops the
 * external dependency in favour of stb_image (public-domain, single-
 * header, MIT-style license). Same LoadJPG signature so callers in
 * r_image.c are unaffected. Resolves the long-standing build-host
 * libjpeg requirement that forced WITH_RETEXTURING=no in build.sh.
 *
 * =======================================================================
 */

#ifdef RETEXTURE

#include "../header/local.h"

/* stb_image needs a few configuration macros set before its
 * implementation include. We only want the JPEG decoder here (TGA stays
 * in tga.c, PNG can be added later as a separate function). Disable
 * HDR / linear-light paths since Q2 textures are sRGB 8-bit. Use the
 * standard malloc family so the engine's later free() on the returned
 * buffer works without surprises. */
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#define STBI_NO_PSD
#define STBI_NO_GIF
#define STBI_NO_PIC
#define STBI_NO_PNM
#define STBI_NO_BMP
#define STBI_NO_THREAD_LOCALS
#define STBI_MALLOC(sz)    malloc(sz)
#define STBI_REALLOC(p,sz) realloc(p,sz)
#define STBI_FREE(p)       free(p)
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

/*
 * Load a JPEG file into RGBA8 pixel data.
 *
 * origname: filename (with or without .jpg extension)
 * pic:      out — malloc'd RGBA8 buffer, caller frees with free()
 * width:    out — image width
 * height:   out — image height
 *
 * On failure, *pic is set to NULL and width/height are untouched.
 */
void
LoadJPG(char *origname, byte **pic, int *width, int *height)
{
	char filename[256];
	byte *rawdata;
	int rawsize;
	int w, h, channels;
	byte *decoded;

	*pic = NULL;

	Q_strlcpy(filename, origname, sizeof(filename));

	/* Add the extension if the caller passed a bare name. */
	if (strcmp(COM_FileExtension(filename), "jpg"))
	{
		Q_strlcat(filename, ".jpg", sizeof(filename));
	}

	/* Pull the file into memory via the engine's filesystem. The engine
	 * owns the rawdata buffer and we MUST FS_FreeFile when done. */
	rawsize = ri.FS_LoadFile(filename, (void **)&rawdata);

	if (!rawdata || rawsize <= 0)
	{
		return;
	}

	/* Decode. STBI_rgb_alpha forces 4-channel output regardless of
	 * source channel count, so we always emit RGBA — matching what the
	 * libjpeg path did via the manual RGB→RGBA expand loop. */
	decoded = stbi_load_from_memory(rawdata, rawsize, &w, &h, &channels,
			STBI_rgb_alpha);

	ri.FS_FreeFile(rawdata);

	if (!decoded)
	{
		ri.Con_Printf(PRINT_ALL, "LoadJPG: stbi_load failed for %s: %s\n",
				filename, stbi_failure_reason());
		return;
	}

	*pic = decoded;
	*width = w;
	*height = h;
}

#endif /* RETEXTURE */
