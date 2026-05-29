/*
 * Copyright (C) 1997-2001 Id Software, Inc.
 * Copyright (C) 2006      Quake2Evolved / KMQuake2 (bloom concept)
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
 * Light bloom — a fixed-function fullscreen post-process re-expressed for
 * the yquake2 5.11 GL1 path from the classic Quake2Evolved/KMQuake2 effect
 * (r_bloom.c). NO ARB_fragment_program / FBO needed: it captures the back
 * buffer with glCopyTexSubImage2D, downsamples into a small effect texture,
 * darkens to isolate the bright areas, applies a cheap separable blur via
 * additive offset passes, and composites the result additively back over
 * the 3D view. Runs at the end of R_RenderView, before the 2D HUD.
 *
 * Fillrate-heavy (several small fullscreen passes), so it is gated per
 * machine via gl_bloom and meant for boxes with GPU headroom (quicksilver
 * under its vsync cap, the iMac, and the Intel/Core2 path).
 *
 * =======================================================================
 */

#include "header/local.h"

cvar_t *gl_bloom;            /* master on/off */
cvar_t *gl_bloom_alpha;      /* composite intensity */
cvar_t *gl_bloom_darken;     /* bright-pass strength (multiply passes) */
cvar_t *gl_bloom_size;       /* effect-texture size (pow2, 64..512) */

image_t *r_bloomscreentexture;  /* pow2 >= view, raw back-buffer copy */
image_t *r_bloomeffecttexture;  /* BLOOM_SIZE^2, downsampled + blurred */

static int screen_tex_w, screen_tex_h; /* pow2 dims of the screen texture */
static int BLOOM_SIZE;                  /* effect-texture edge (pow2) */

/* View rectangle currently being processed (from r_newrefdef). */
static int   v_x, v_y, v_w, v_h;
/* texcoords of the captured view within the pow2 screen texture */
static float scr_tcw, scr_tch;

static qboolean bloom_inited = false;

static int
R_Bloom_RoundUpPow2(int v)
{
	int p = 1;
	while (p < v)
	{
		p *= 2;
	}
	return p;
}

void
R_InitBloomTextures(void)
{
	byte *data;
	int size;

	bloom_inited = false;

	if (!gl_bloom->value)
	{
		return;
	}

	/* effect texture size — clamp to a sane pow2 in [64,512] */
	BLOOM_SIZE = (int)gl_bloom_size->value;
	if (BLOOM_SIZE < 64)
	{
		BLOOM_SIZE = 64;
	}
	BLOOM_SIZE = R_Bloom_RoundUpPow2(BLOOM_SIZE);
	if (BLOOM_SIZE > 512)
	{
		BLOOM_SIZE = 512;
	}

	/* screen texture must be pow2 and at least the window size */
	screen_tex_w = R_Bloom_RoundUpPow2(vid.width);
	screen_tex_h = R_Bloom_RoundUpPow2(vid.height);

	/* don't let the effect texture exceed the screen texture */
	while (BLOOM_SIZE > screen_tex_w || BLOOM_SIZE > screen_tex_h)
	{
		BLOOM_SIZE /= 2;
	}
	if (BLOOM_SIZE < 32)
	{
		return; /* window too small — leave disabled */
	}

	size = screen_tex_w * screen_tex_h * 4;
	data = malloc(size);
	if (!data)
	{
		return;
	}
	memset(data, 0, size);
	r_bloomscreentexture = R_LoadPic("***bloomscreen***", data,
			screen_tex_w, 0, screen_tex_h, 0, it_pic, 32);

	memset(data, 0, BLOOM_SIZE * BLOOM_SIZE * 4);
	r_bloomeffecttexture = R_LoadPic("***bloomeffect***", data,
			BLOOM_SIZE, 0, BLOOM_SIZE, 0, it_pic, 32);
	free(data);

	bloom_inited = true;
}

/* Draw a textured quad in the current ortho workspace. tcw/tch are the
 * texcoord extents (top-right); the quad spans (x,y)..(x+w,y+h). */
static void
R_Bloom_Quad(float x, float y, float w, float h, float tcw, float tch)
{
	qglBegin(GL_QUADS);
	qglTexCoord2f(0, tch);   qglVertex2f(x, y);
	qglTexCoord2f(0, 0);     qglVertex2f(x, y + h);
	qglTexCoord2f(tcw, 0);   qglVertex2f(x + w, y + h);
	qglTexCoord2f(tcw, tch); qglVertex2f(x + w, y);
	qglEnd();
}

/* Single offset additive sample of the effect texture onto itself. */
static void
R_Bloom_SamplePass(int xofs, int yofs, float intensity)
{
	qglColor4f(intensity, intensity, intensity, 1.0f);
	R_Bloom_Quad(xofs, yofs, BLOOM_SIZE, BLOOM_SIZE, 1.0f, 1.0f);
}

void
R_Bloom(void)
{
	int i;
	float blur;

	if (!gl_bloom->value || (r_newrefdef.rdflags & RDF_NOWORLDMODEL))
	{
		return;
	}

	if (!bloom_inited || !r_bloomeffecttexture || !r_bloomscreentexture)
	{
		R_InitBloomTextures();
		if (!bloom_inited)
		{
			return;
		}
	}

	/* drain any pending batch before we take over GL state */
	R_ApplyGLBuffer();

	v_x = r_newrefdef.x;
	v_y = vid.height - r_newrefdef.height - r_newrefdef.y; /* GL origin = bottom-left */
	v_w = r_newrefdef.width;
	v_h = r_newrefdef.height;

	scr_tcw = (float)v_w / (float)screen_tex_w;
	scr_tch = (float)v_h / (float)screen_tex_h;

	/* --- common 2D state for the post pass --- */
	qglDisable(GL_DEPTH_TEST);
	qglDepthMask(GL_FALSE);
	qglDisable(GL_CULL_FACE);
	qglDisable(GL_ALPHA_TEST);
	qglDisable(GL_FOG);
	if (qglSelectTextureSGIS || qglActiveTextureARB)
	{
		R_EnableMultitexture(false); /* single TMU0 for all bloom passes */
	}
	qglMatrixMode(GL_PROJECTION);
	qglPushMatrix();
	qglMatrixMode(GL_MODELVIEW);
	qglPushMatrix();
	qglLoadIdentity();

	/* 1. capture the rendered view into the screen texture (1:1) */
	R_Bind(r_bloomscreentexture->texnum);
	qglCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, v_x, v_y, v_w, v_h);

	/* 2. downsample: render the captured view into the BLOOM_SIZE corner,
	 *    then copy that into the effect texture. */
	qglViewport(0, 0, BLOOM_SIZE, BLOOM_SIZE);
	qglMatrixMode(GL_PROJECTION);
	qglLoadIdentity();
	qglOrtho(0, BLOOM_SIZE, BLOOM_SIZE, 0, -10, 100);
	qglMatrixMode(GL_MODELVIEW);
	qglLoadIdentity();

	R_TexEnv(GL_MODULATE);
	qglDisable(GL_BLEND);
	qglColor4f(1, 1, 1, 1);
	R_Bind(r_bloomscreentexture->texnum);
	R_Bloom_Quad(0, 0, BLOOM_SIZE, BLOOM_SIZE, scr_tcw, scr_tch);

	R_Bind(r_bloomeffecttexture->texnum);
	qglCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0, BLOOM_SIZE, BLOOM_SIZE);

	qglEnable(GL_BLEND);

	/* 3. darkening passes — multiply the small image by itself to crush
	 *    midtones and keep only the bright sources. */
	if (gl_bloom_darken->value)
	{
		qglBlendFunc(GL_DST_COLOR, GL_ZERO);
		R_Bind(r_bloomeffecttexture->texnum);
		for (i = 0; i < (int)gl_bloom_darken->value; i++)
		{
			qglColor4f(1, 1, 1, 1);
			R_Bloom_Quad(0, 0, BLOOM_SIZE, BLOOM_SIZE, 1.0f, 1.0f);
		}
		qglCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0, BLOOM_SIZE, BLOOM_SIZE);
	}

	/* 4. separable-ish blur: additive offset taps in X then Y, re-copying
	 *    the accumulator between axes. */
	blur = 1.0f;
	qglBlendFunc(GL_ONE, GL_ONE);
	R_Bind(r_bloomeffecttexture->texnum);

	qglColor4f(0.5f, 0.5f, 0.5f, 1.0f); /* base re-add */
	R_Bloom_Quad(0, 0, BLOOM_SIZE, BLOOM_SIZE, 1.0f, 1.0f);
	for (i = 1; i <= 4; i++)
	{
		float w = blur * (1.0f - (i / 5.0f)) * 0.3f;
		R_Bloom_SamplePass(i, 0, w);
		R_Bloom_SamplePass(-i, 0, w);
	}
	qglCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0, BLOOM_SIZE, BLOOM_SIZE);

	R_Bind(r_bloomeffecttexture->texnum);
	qglColor4f(0.5f, 0.5f, 0.5f, 1.0f);
	R_Bloom_Quad(0, 0, BLOOM_SIZE, BLOOM_SIZE, 1.0f, 1.0f);
	for (i = 1; i <= 4; i++)
	{
		float w = blur * (1.0f - (i / 5.0f)) * 0.3f;
		R_Bloom_SamplePass(0, i, w);
		R_Bloom_SamplePass(0, -i, w);
	}
	qglCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0, BLOOM_SIZE, BLOOM_SIZE);

	/* 5. composite over the full view rectangle.
	 *
	 * The downsample/darken/blur passes above rendered into the bottom-left
	 * corner of the BACK BUFFER (the sample workspace), corrupting it. So
	 * first blit the captured original scene back over the whole view in
	 * REPLACE mode — this restores everything including that corner — then
	 * add the bloom on top. */
	qglViewport(0, 0, vid.width, vid.height);
	qglMatrixMode(GL_PROJECTION);
	qglLoadIdentity();
	qglOrtho(0, vid.width, vid.height, 0, -10, 100);
	qglMatrixMode(GL_MODELVIEW);
	qglLoadIdentity();

	/* 5a. restore the scene from the captured screen texture */
	qglDisable(GL_BLEND);
	R_TexEnv(GL_REPLACE);
	qglColor4f(1, 1, 1, 1);
	R_Bind(r_bloomscreentexture->texnum);
	R_Bloom_Quad(r_newrefdef.x, r_newrefdef.y,
			r_newrefdef.width, r_newrefdef.height, scr_tcw, scr_tch);

	/* 5b. add the bloom */
	qglEnable(GL_BLEND);
	R_TexEnv(GL_MODULATE);
	qglBlendFunc(GL_ONE, GL_ONE);
	R_Bind(r_bloomeffecttexture->texnum);
	{
		float a = gl_bloom_alpha->value;
		qglColor4f(a, a, a, 1.0f);
		R_Bloom_Quad(r_newrefdef.x, r_newrefdef.y,
				r_newrefdef.width, r_newrefdef.height, 1.0f, 1.0f);
	}

	/* 6. restore state. The caller runs R_SetGL2D next (HUD) and
	 *    R_SetupGL next frame, but leave things tidy regardless. */
	qglColor4f(1, 1, 1, 1);
	qglBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
	qglDisable(GL_BLEND);
	qglMatrixMode(GL_PROJECTION);
	qglPopMatrix();
	qglMatrixMode(GL_MODELVIEW);
	qglPopMatrix();
	qglViewport(0, 0, vid.width, vid.height);
	qglDepthMask(GL_TRUE);
	qglEnable(GL_DEPTH_TEST);
}
