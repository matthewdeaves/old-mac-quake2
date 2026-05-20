/*
 * Copyright (C) 1997-2001 Id Software, Inc.
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
 * Surface generation and drawing
 *
 * =======================================================================
 */

#include <assert.h>
#include "header/local.h"

int c_visible_lightmaps;
int c_visible_textures;
static vec3_t modelorg; /* relative to viewpoint */
msurface_t *r_alpha_surfaces;

gllightmapstate_t gl_lms;

void LM_InitBlock(void);
void LM_UploadBlock(qboolean dynamic);
qboolean LM_AllocBlock(int w, int h, int *x, int *y);

void R_SetCacheState(msurface_t *surf);
void R_BuildLightMap(msurface_t *surf, byte *dest, int stride);

/*
 * Returns the proper texture for a given time and base texture
 */
image_t *
R_TextureAnimation(mtexinfo_t *tex)
{
	int c;

	if (!tex->next)
	{
		return tex->image;
	}

	c = currententity->frame % tex->numframes;

	while (c)
	{
		tex = tex->next;
		c--;
	}

	return tex->image;
}

/*
 * Append a brush-surface polygon to the current buffer batch (Phase B
 * group-draw). The caller must have set up the batch state via
 * R_UpdateGLBuffer(buf_singletex, ...) already; the buffer flushes
 * automatically when the texture or surface flags change. R_DrawGLPoly
 * is the static-coord variant; R_DrawGLFlowingPoly bakes in the time-
 * based scroll offset for SURF_FLOWING surfaces.
 */
void
R_DrawGLPoly(glpoly_t *p)
{
	int i;
	float *v;
	int nv = p->numverts;

	R_SetBufferIndices(GL_TRIANGLE_FAN, nv);
	v = p->verts[0];

	for (i = 0; i < nv; i++, v += VERTEXSIZE)
	{
		GLBUFFER_VERTEX(v[0], v[1], v[2])
		GLBUFFER_SINGLETEX(v[3], v[4])
	}
}

void
R_DrawGLFlowingPoly(msurface_t *fa)
{
	int i;
	float *v;
	glpoly_t *p;
	float scroll;
	int nv;

	p = fa->polys;
	nv = p->numverts;

	scroll = -64 * ((r_newrefdef.time / 40.0) - (int)(r_newrefdef.time / 40.0));

	if (scroll == 0.0)
	{
		scroll = -64.0;
	}

	R_SetBufferIndices(GL_TRIANGLE_FAN, nv);
	v = p->verts[0];

	for (i = 0; i < nv; i++, v += VERTEXSIZE)
	{
		GLBUFFER_VERTEX(v[0], v[1], v[2])
		GLBUFFER_SINGLETEX(v[3] + scroll, v[4])
	}
}

void
R_DrawTriangleOutlines(void)
{
	int i, j;
	glpoly_t *p;

	if (!gl_showtris->value)
	{
		return;
	}

	/* Drain pending batch before raw immediate-mode line draws. */
	R_ApplyGLBuffer();

	qglDisable(GL_TEXTURE_2D);
	qglDisable(GL_DEPTH_TEST);
	qglColor4f(1, 1, 1, 1);

	for (i = 0; i < MAX_LIGHTMAPS; i++)
	{
		msurface_t *surf;

		for (surf = gl_lms.lightmap_surfaces[i];
			 surf != 0;
			 surf = surf->lightmapchain)
		{
			p = surf->polys;

			for ( ; p; p = p->chain)
			{
				for (j = 2; j < p->numverts; j++)
				{
					qglBegin(GL_LINE_STRIP);
					qglVertex3fv(p->verts[0]);
					qglVertex3fv(p->verts[j - 1]);
					qglVertex3fv(p->verts[j]);
					qglVertex3fv(p->verts[0]);
					qglEnd();
				}
			}
		}
	}

	qglEnable(GL_DEPTH_TEST);
	qglEnable(GL_TEXTURE_2D);
}

/*
 * Render a chain of lightmap polygons via per-polygon vertex array
 * draws. Used by R_BlendLightmaps's second-pass lightmap blend (dual-
 * pass renderer path) where the polygon's lightmap UVs live at v[5..6]
 * rather than the color UVs at v[3..4]. Each chain link gets one
 * glDrawArrays. We don't use the global gl_buf here because the
 * per-polygon offsets vary in the soffset/toffset branch — interleaving
 * those would require a separate UV scratch per polygon. Single glDraw
 * per polygon still beats per-vertex qglBegin/End substantially on
 * 1999-era drivers.
 *
 * Caller MUST have called R_ApplyGLBuffer to drain any pending
 * single-/multitex batch before invoking this; we don't do it here
 * because we'd lose the no-state-change optimization in the common
 * call site (R_BlendLightmaps inside a tight texture loop).
 */
void
R_DrawGLPolyChain(glpoly_t *p, float soffset, float toffset)
{
	if ((soffset == 0) && (toffset == 0))
	{
		for ( ; p != 0; p = p->chain)
		{
			float *v;

			v = p->verts[0];

			if (v == NULL)
			{
				fprintf(stderr, "BUGFIX: R_DrawGLPolyChain: v==NULL\n");
				return;
			}

			qglEnableClientState(GL_VERTEX_ARRAY);
			qglEnableClientState(GL_TEXTURE_COORD_ARRAY);
			qglVertexPointer(3, GL_FLOAT, VERTEXSIZE * sizeof(GLfloat), v);
			qglTexCoordPointer(2, GL_FLOAT, VERTEXSIZE * sizeof(GLfloat), v + 5);
			qglDrawArrays(GL_TRIANGLE_FAN, 0, p->numverts);
			qglDisableClientState(GL_TEXTURE_COORD_ARRAY);
			qglDisableClientState(GL_VERTEX_ARRAY);
		}
	}
	else
	{
		/* per-polygon UV scratch — sized for the largest polygon we
		 * might encounter. MAX_POLY_VERTS isn't defined in 5.11; use a
		 * conservative cap. Q2 BSP polys are clipped by the loader to
		 * MAX_VERT_LIGHTMAPS which is well under 64. */
		GLfloat uvbuf[64 * 2];

		for ( ; p != 0; p = p->chain)
		{
			float *v;
			int j, nv;

			v = p->verts[0];
			nv = p->numverts;

			if (nv > 64)
			{
				/* Should never happen with id1 maps; bail rather than
				 * stomp the stack. */
				continue;
			}

			for (j = 0; j < nv; j++)
			{
				uvbuf[j * 2]     = v[j * VERTEXSIZE + 5] - soffset;
				uvbuf[j * 2 + 1] = v[j * VERTEXSIZE + 6] - toffset;
			}

			qglEnableClientState(GL_VERTEX_ARRAY);
			qglEnableClientState(GL_TEXTURE_COORD_ARRAY);
			qglVertexPointer(3, GL_FLOAT, VERTEXSIZE * sizeof(GLfloat), v);
			qglTexCoordPointer(2, GL_FLOAT, 0, uvbuf);
			qglDrawArrays(GL_TRIANGLE_FAN, 0, nv);
			qglDisableClientState(GL_TEXTURE_COORD_ARRAY);
			qglDisableClientState(GL_VERTEX_ARRAY);
		}
	}
}

/*
 * This routine takes all the given light mapped surfaces
 * in the world and blends them into the framebuffer.
 */
void
R_BlendLightmaps(void)
{
	int i;
	msurface_t *surf, *newdrawsurf = 0;

	/* don't bother if we're set to fullbright */
	if (gl_fullbright->value)
	{
		return;
	}

	if (!r_worldmodel->lightdata)
	{
		return;
	}

	/* Drain any pending opaque batch — the blend-lightmap pass uses
	 * its own depth/blend/texenv state and emits via R_DrawGLPolyChain
	 * (per-poly vertex arrays, not the gl_buf accumulator). Any batch
	 * still pending would draw before the depth mask change below,
	 * which is fine — but we want a clean state boundary. */
	R_ApplyGLBuffer();

	/* don't bother writing Z */
	qglDepthMask(0);

	/* set the appropriate blending mode unless
	   we're only looking at the lightmaps. */
	if (!gl_lightmap->value)
	{
		qglEnable(GL_BLEND);

		if (gl_saturatelighting->value)
		{
			qglBlendFunc(GL_ONE, GL_ONE);
		}
		else
		{
			qglBlendFunc(GL_ZERO, GL_SRC_COLOR);
		}
	}

	if (currentmodel == r_worldmodel)
	{
		c_visible_lightmaps = 0;
	}

	/* render static lightmaps first */
	for (i = 1; i < MAX_LIGHTMAPS; i++)
	{
		if (gl_lms.lightmap_surfaces[i])
		{
			if (currentmodel == r_worldmodel)
			{
				c_visible_lightmaps++;
			}

			R_Bind(gl_state.lightmap_textures + i);

			for (surf = gl_lms.lightmap_surfaces[i];
				 surf != 0;
				 surf = surf->lightmapchain)
			{
				if (surf->polys)
				{
					R_DrawGLPolyChain(surf->polys, 0, 0);
				}
			}
		}
	}

	/* render dynamic lightmaps */
	if (gl_dynamic->value)
	{
		LM_InitBlock();

		R_Bind(gl_state.lightmap_textures + 0);

		if (currentmodel == r_worldmodel)
		{
			c_visible_lightmaps++;
		}

		newdrawsurf = gl_lms.lightmap_surfaces[0];

		for (surf = gl_lms.lightmap_surfaces[0];
			 surf != 0;
			 surf = surf->lightmapchain)
		{
			int smax, tmax;
			byte *base;

			smax = (surf->extents[0] >> 4) + 1;
			tmax = (surf->extents[1] >> 4) + 1;

			if (LM_AllocBlock(smax, tmax, &surf->dlight_s, &surf->dlight_t))
			{
				base = gl_lms.lightmap_buffer;
				base += (surf->dlight_t * BLOCK_WIDTH +
						surf->dlight_s) * LIGHTMAP_BYTES;

				R_BuildLightMap(surf, base, BLOCK_WIDTH * LIGHTMAP_BYTES);
			}
			else
			{
				msurface_t *drawsurf;

				/* upload what we have so far */
				LM_UploadBlock(true);

				/* draw all surfaces that use this lightmap */
				for (drawsurf = newdrawsurf;
					 drawsurf != surf;
					 drawsurf = drawsurf->lightmapchain)
				{
					if (drawsurf->polys)
					{
						R_DrawGLPolyChain(drawsurf->polys,
								(drawsurf->light_s - drawsurf->dlight_s) * (1.0 / 128.0),
								(drawsurf->light_t - drawsurf->dlight_t) * (1.0 / 128.0));
					}
				}

				newdrawsurf = drawsurf;

				/* clear the block */
				LM_InitBlock();

				/* try uploading the block now */
				if (!LM_AllocBlock(smax, tmax, &surf->dlight_s, &surf->dlight_t))
				{
					ri.Sys_Error(ERR_FATAL,
							"Consecutive calls to LM_AllocBlock(%d,%d) failed (dynamic)\n",
							smax, tmax);
				}

				base = gl_lms.lightmap_buffer;
				base += (surf->dlight_t * BLOCK_WIDTH +
						surf->dlight_s) * LIGHTMAP_BYTES;

				R_BuildLightMap(surf, base, BLOCK_WIDTH * LIGHTMAP_BYTES);
			}
		}

		/* draw remainder of dynamic lightmaps that haven't been uploaded yet */
		if (newdrawsurf)
		{
			LM_UploadBlock(true);
		}

		for (surf = newdrawsurf; surf != 0; surf = surf->lightmapchain)
		{
			if (surf->polys)
			{
				R_DrawGLPolyChain(surf->polys,
						(surf->light_s - surf->dlight_s) * (1.0 / 128.0),
						(surf->light_t - surf->dlight_t) * (1.0 / 128.0));
			}
		}
	}

	/* restore state */
	qglDisable(GL_BLEND);
	qglBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
	qglDepthMask(1);
}

void
R_RenderBrushPoly(msurface_t *fa)
{
	int maps;
	image_t *image;
	qboolean is_dynamic = false;

	c_brush_polys++;

	image = R_TextureAnimation(fa->texinfo);

	if (fa->flags & SURF_DRAWTURB)
	{
		/* warp surfaces have their own bespoke render path that
		 * sources a different texenv / blend state and emits its own
		 * geometry; drain any pending batch first so we don't carry
		 * stale buffer state into immediate-mode emit. */
		R_ApplyGLBuffer();
		R_Bind(image->texnum);
		R_TexEnv(GL_MODULATE);
		qglColor4f(gl_state.inverse_intensity, gl_state.inverse_intensity,
				gl_state.inverse_intensity, 1.0F);
		R_EmitWaterPolys(fa);
		R_TexEnv(GL_REPLACE);

		return;
	}

	/* Standard brush surface: buffer-batched single-texture draw.
	 * R_UpdateGLBuffer flushes if state changed (different texture or
	 * flags), then sets up the new batch. The R_DrawGLPoly /
	 * R_DrawGLFlowingPoly calls below accumulate this surface's verts
	 * into that batch. The caller (R_DrawTextureChains) drains the
	 * final batch via R_ApplyGLBuffer at the end of each phase. */
	R_UpdateGLBuffer(buf_singletex, image->texnum, 0, fa->flags, 1.0f);

	if (fa->texinfo->flags & SURF_FLOWING)
	{
		R_DrawGLFlowingPoly(fa);
	}
	else
	{
		R_DrawGLPoly(fa->polys);
	}

	/* check for lightmap modification */
	for (maps = 0; maps < MAXLIGHTMAPS && fa->styles[maps] != 255; maps++)
	{
		if (r_newrefdef.lightstyles[fa->styles[maps]].white !=
			fa->cached_light[maps])
		{
			goto dynamic;
		}
	}

	/* dynamic this frame or dynamic previously */
	if (fa->dlightframe == r_framecount)
	{
	dynamic:

		if (gl_dynamic->value)
		{
			if (!(fa->texinfo->flags &
				  (SURF_SKY | SURF_TRANS33 | 
				   SURF_TRANS66 | SURF_WARP)))
			{
				is_dynamic = true;
			}
		}
	}

	if (is_dynamic)
	{
		/* Fix upstream Q2 OOB: the cppcheck warning at r_surf.c:442
		 * is real — if the loop above ran all the way to MAXLIGHTMAPS
		 * (i.e. every slot held a non-terminator style), `maps` ==
		 * MAXLIGHTMAPS here and fa->styles[maps] reads 1 byte past the
		 * 4-byte array. Clamp the index so the read stays in-bounds.
		 * When clamping kicks in, the value at MAXLIGHTMAPS-1 is by
		 * definition non-255 (loop ran to completion), so the
		 * `>=32 || ==0` check evaluates identically to the OOB read on
		 * normal id1 levels — preserves behaviour. */
		int safe_map = (maps < MAXLIGHTMAPS) ? maps : MAXLIGHTMAPS - 1;
		if (((fa->styles[safe_map] >= 32) ||
			 (fa->styles[safe_map] == 0)) &&
			  (fa->dlightframe != r_framecount))
		{
			unsigned temp[34 * 34];
			int smax, tmax;

			smax = (fa->extents[0] >> 4) + 1;
			tmax = (fa->extents[1] >> 4) + 1;

			R_BuildLightMap(fa, (void *)temp, smax * 4);
			R_SetCacheState(fa);

			R_ApplyGLBuffer();
			R_Bind(gl_state.lightmap_textures + fa->lightmaptexturenum);

			qglTexSubImage2D(GL_TEXTURE_2D, 0, fa->light_s, fa->light_t,
					smax, tmax, GL_LIGHTMAP_FORMAT, GL_UNSIGNED_BYTE, temp);

			fa->lightmapchain = gl_lms.lightmap_surfaces[fa->lightmaptexturenum];
			gl_lms.lightmap_surfaces[fa->lightmaptexturenum] = fa;
		}
		else
		{
			fa->lightmapchain = gl_lms.lightmap_surfaces[0];
			gl_lms.lightmap_surfaces[0] = fa;
		}
	}
	else
	{
		fa->lightmapchain = gl_lms.lightmap_surfaces[fa->lightmaptexturenum];
		gl_lms.lightmap_surfaces[fa->lightmaptexturenum] = fa;
	}
}

/*
 * Draw water surfaces and windows.
 * The BSP tree is waled front to back, so unwinding the chain
 * of alpha_surfaces will draw back to front, giving proper ordering.
 */
void
R_DrawAlphaSurfaces(void)
{
	msurface_t *s;

	/* go back to the world matrix */
	qglLoadMatrixf(r_world_matrix);

	/* Drain any pending opaque batch — the alpha pass requires GL_BLEND
	 * enabled and GL_MODULATE texenv, neither of which match the
	 * default opaque-batch state set by R_ApplyGLBuffer. */
	R_ApplyGLBuffer();

	qglEnable(GL_BLEND);
	R_TexEnv(GL_MODULATE);

	for (s = r_alpha_surfaces; s; s = s->texturechain)
	{
		c_brush_polys++;

		if (s->flags & SURF_DRAWTURB)
		{
			/* Warp surfaces emit their own immediate-mode geometry
			 * via R_EmitWaterPolys; drain the current alpha batch
			 * (different texture/alpha than the warp surface's) and
			 * fall back to legacy color path for this one surface. */
			float intens = gl_state.inverse_intensity;
			float alpha = (s->texinfo->flags & SURF_TRANS33) ? 0.33f
					: (s->texinfo->flags & SURF_TRANS66) ? 0.66f : 1.0f;

			R_ApplyGLBuffer();
			R_Bind(s->texinfo->image->texnum);
			qglColor4f(intens, intens, intens, alpha);
			R_EmitWaterPolys(s);
		}
		else
		{
			float alpha = (s->texinfo->flags & SURF_TRANS33) ? 0.33f
					: (s->texinfo->flags & SURF_TRANS66) ? 0.66f : 1.0f;

			/* R_UpdateGLBuffer flushes the pending batch if texture
			 * or alpha changed since the previous surface, then sets
			 * up the new buf_alpha batch. R_ApplyGLBuffer's buf_alpha
			 * path will issue qglColor4f(intens, intens, intens,
			 * alpha) at draw time. */
			R_UpdateGLBuffer(buf_alpha, s->texinfo->image->texnum, 0, 0, alpha);

			if (s->texinfo->flags & SURF_FLOWING)
			{
				R_DrawGLFlowingPoly(s);
			}
			else
			{
				R_DrawGLPoly(s->polys);
			}
		}
	}

	/* Drain final alpha batch. */
	R_ApplyGLBuffer();

	R_TexEnv(GL_REPLACE);
	qglColor4f(1, 1, 1, 1);
	qglDisable(GL_BLEND);

	r_alpha_surfaces = NULL;
}

void
R_DrawTextureChains(void)
{
	int i;
	msurface_t *s;
	image_t *image;

	c_visible_textures = 0;

	if (!qglSelectTextureSGIS && !qglActiveTextureARB)
	{
		/* Dual-pass renderer path: each surface emits its color
		 * polygon here; the lightmap second pass runs later via
		 * R_BlendLightmaps. R_RenderBrushPoly accumulates each
		 * polygon into the singletex batch. */
		for (i = 0, image = gltextures; i < numgltextures; i++, image++)
		{
			if (!image->registration_sequence)
			{
				continue;
			}

			s = image->texturechain;

			if (!s)
			{
				continue;
			}

			c_visible_textures++;

			for ( ; s; s = s->texturechain)
			{
				R_RenderBrushPoly(s);
			}

			image->texturechain = NULL;
		}
		/* Drain the final singletex batch. */
		R_ApplyGLBuffer();
	}
	else
	{
		/* Multitex path: opaque non-warp surfaces were already drawn
		 * inline during R_RecursiveWorldNode (via R_RenderLightmappedPoly
		 * directly from the BSP walk — see r_surf.c:1127). At this
		 * point the texture chain holds only SURF_DRAWTURB warp
		 * surfaces that the BSP walk deferred. The first inner loop
		 * is therefore effectively a no-op in the standard renderer
		 * config — kept verbatim from upstream so any non-default
		 * code paths that DO populate the chain still work. */
		for (i = 0, image = gltextures; i < numgltextures; i++, image++)
		{
			if (!image->registration_sequence)
			{
				continue;
			}

			if (!image->texturechain)
			{
				continue;
			}

			c_visible_textures++;

			for (s = image->texturechain; s; s = s->texturechain)
			{
				if (!(s->flags & SURF_DRAWTURB))
				{
					R_RenderBrushPoly(s);
				}
			}
		}
		/* Drain whatever the (typically empty) above loop accumulated
		 * before disabling multitex. R_EnableMultitexture changes TMU
		 * state, so any pending batch must apply first. */
		R_ApplyGLBuffer();

		R_EnableMultitexture(false);

		for (i = 0, image = gltextures; i < numgltextures; i++, image++)
		{
			if (!image->registration_sequence)
			{
				continue;
			}

			s = image->texturechain;

			if (!s)
			{
				continue;
			}

			for ( ; s; s = s->texturechain)
			{
				if (s->flags & SURF_DRAWTURB)
				{
					R_RenderBrushPoly(s);
				}
			}

			image->texturechain = NULL;
		}
		/* Drain the warp-singletex batch. */
		R_ApplyGLBuffer();
	}

	R_TexEnv(GL_REPLACE);
}

static void
R_RenderLightmappedPoly(msurface_t *surf)
{
	int i, nv = surf->polys->numverts;
	int map;
	float *v;
	image_t *image = R_TextureAnimation(surf->texinfo);
	qboolean is_dynamic = false;
	unsigned lmtex = surf->lightmaptexturenum;
	glpoly_t *p;
	qboolean flowing;
	float scroll = 0.0f;

	for (map = 0; map < MAXLIGHTMAPS && surf->styles[map] != 255; map++)
	{
		if (r_newrefdef.lightstyles[surf->styles[map]].white !=
			surf->cached_light[map])
		{
			goto dynamic;
		}
	}

	if (surf->dlightframe == r_framecount)
	{
	dynamic:

		if (gl_dynamic->value)
		{
			if (!(surf->texinfo->flags &
				  (SURF_SKY | SURF_TRANS33 | SURF_TRANS66 | SURF_WARP)))
			{
				is_dynamic = true;
			}
		}
	}

	/* Dynamic-rebuild path: rebuild the lightmap subrect, upload to the
	 * appropriate atlas slot, decide which lmtex to draw with. Note the
	 * R_MBind here is for the qglTexSubImage2D upload's bind target,
	 * NOT for the draw — the buffer's R_ApplyGLBuffer reapplies texture
	 * binding at flush time using gl_buf.texture[1] = lmtex (set via
	 * the R_UpdateGLBuffer call below). */
	if (is_dynamic)
	{
		unsigned temp[128 * 128];
		int smax, tmax;
		/* Mirror of the OOB fix in R_RenderBrushPoly above. If the
		 * styles-scan loop above ran to completion, `map` is exactly
		 * MAXLIGHTMAPS and reading surf->styles[map] is OOB. Clamp to
		 * the last valid index — when the loop ran full, that slot
		 * holds a non-terminator value, so the (>=32 || ==0) test
		 * lands on the same answer as the OOB read on id1 levels. */
		int safe_map = (map < MAXLIGHTMAPS) ? map : MAXLIGHTMAPS - 1;

		if (((surf->styles[safe_map] >= 32) ||
			 (surf->styles[safe_map] == 0)) &&
				(surf->dlightframe != r_framecount))
		{
			smax = (surf->extents[0] >> 4) + 1;
			tmax = (surf->extents[1] >> 4) + 1;

			R_BuildLightMap(surf, (void *)temp, smax * 4);
			R_SetCacheState(surf);

			/* Drain any pending batch first — qglTexSubImage2D
			 * needs a deterministic bound texture, and we're about
			 * to redirect TMU1's binding. */
			R_ApplyGLBuffer();
			R_MBind(QGL_TEXTURE1, gl_state.lightmap_textures + surf->lightmaptexturenum);

			lmtex = surf->lightmaptexturenum;

			qglTexSubImage2D(GL_TEXTURE_2D, 0, surf->light_s, surf->light_t,
					smax, tmax, GL_LIGHTMAP_FORMAT, GL_UNSIGNED_BYTE, temp);
		}
		else
		{
			smax = (surf->extents[0] >> 4) + 1;
			tmax = (surf->extents[1] >> 4) + 1;

			R_BuildLightMap(surf, (void *)temp, smax * 4);

			R_ApplyGLBuffer();
			R_MBind(QGL_TEXTURE1, gl_state.lightmap_textures + 0);

			lmtex = 0;

			qglTexSubImage2D(GL_TEXTURE_2D, 0, surf->light_s, surf->light_t,
					smax, tmax, GL_LIGHTMAP_FORMAT, GL_UNSIGNED_BYTE, temp);
		}
	}

	c_brush_polys++;

	/* Buffer state for this batch. Flushes the pending batch if the
	 * color texture or lightmap texture changed since the last surface.
	 * Surfaces with the same image + lightmaptexturenum accumulate
	 * into a single glDrawElements at the next phase boundary. */
	R_UpdateGLBuffer(buf_mtex, image->texnum, lmtex, 0, 1.0f);

	flowing = (surf->texinfo->flags & SURF_FLOWING) ? true : false;
	if (flowing)
	{
		scroll = -64 *
				 ((r_newrefdef.time / 40.0) - (int)(r_newrefdef.time / 40.0));

		if (scroll == 0.0)
		{
			scroll = -64.0;
		}
	}

	for (p = surf->polys; p; p = p->chain)
	{
		v = p->verts[0];
		R_SetBufferIndices(GL_TRIANGLE_FAN, nv);

		for (i = 0; i < nv; i++, v += VERTEXSIZE)
		{
			GLBUFFER_VERTEX(v[0], v[1], v[2])
			GLBUFFER_MULTITEX(v[3] + scroll, v[4], v[5], v[6])
		}
	}
}

void
R_DrawInlineBModel(void)
{
	int i, k;
	cplane_t *pplane;
	float dot;
	msurface_t *psurf;
	dlight_t *lt;

	/* calculate dynamic lighting for bmodel */
	if (!gl_flashblend->value)
	{
		lt = r_newrefdef.dlights;

		for (k = 0; k < r_newrefdef.num_dlights; k++, lt++)
		{
			R_MarkLights(lt, 1 << k,
					currentmodel->nodes + currentmodel->firstnode);
		}
	}

	psurf = &currentmodel->surfaces[currentmodel->firstmodelsurface];

	if (currententity->flags & RF_TRANSLUCENT)
	{
		qglEnable(GL_BLEND);
		qglColor4f(1, 1, 1, 0.25);
		R_TexEnv(GL_MODULATE);
	}

	/* draw texture */
	for (i = 0; i < currentmodel->nummodelsurfaces; i++, psurf++)
	{
		/* find which side of the node we are on */
		pplane = psurf->plane;

		dot = DotProduct(modelorg, pplane->normal) - pplane->dist;

		/* draw the polygon */
		if (((psurf->flags & SURF_PLANEBACK) && (dot < -BACKFACE_EPSILON)) ||
			(!(psurf->flags & SURF_PLANEBACK) && (dot > BACKFACE_EPSILON)))
		{
			if (psurf->texinfo->flags & (SURF_TRANS33 | SURF_TRANS66))
			{
				/* add to the translucent chain */
				psurf->texturechain = r_alpha_surfaces;
				r_alpha_surfaces = psurf;
			}
			else if (qglMTexCoord2fSGIS && !(psurf->flags & SURF_DRAWTURB))
			{
				R_RenderLightmappedPoly(psurf);
			}
			else
			{
				/* Switching between multitex and singletex draws.
				 * Flush whatever buffer batch was pending so the
				 * state transition is clean. */
				R_ApplyGLBuffer();
				R_EnableMultitexture(false);
				R_RenderBrushPoly(psurf);
				R_ApplyGLBuffer();
				R_EnableMultitexture(true);
			}
		}
	}
	/* Drain final bmodel batch. */
	R_ApplyGLBuffer();

	if (!(currententity->flags & RF_TRANSLUCENT))
	{
		if (!qglMTexCoord2fSGIS)
		{
			R_BlendLightmaps();
		}
	}
	else
	{
		qglDisable(GL_BLEND);
		qglColor4f(1, 1, 1, 1);
		R_TexEnv(GL_REPLACE);
	}
}

void
R_DrawBrushModel(entity_t *e)
{
	vec3_t mins, maxs;
	int i;
	qboolean rotated;

	if (currentmodel->nummodelsurfaces == 0)
	{
		return;
	}

	currententity = e;
	gl_state.currenttextures[0] = gl_state.currenttextures[1] = -1;

	if (e->angles[0] || e->angles[1] || e->angles[2])
	{
		rotated = true;

		for (i = 0; i < 3; i++)
		{
			mins[i] = e->origin[i] - currentmodel->radius;
			maxs[i] = e->origin[i] + currentmodel->radius;
		}
	}
	else
	{
		rotated = false;
		VectorAdd(e->origin, currentmodel->mins, mins);
		VectorAdd(e->origin, currentmodel->maxs, maxs);
	}

	if (R_CullBox(mins, maxs))
	{
		return;
	}

	if (gl_zfix->value)
	{
		qglEnable(GL_POLYGON_OFFSET_FILL);
	}

	qglColor3f(1, 1, 1);
	memset(gl_lms.lightmap_surfaces, 0, sizeof(gl_lms.lightmap_surfaces));

	VectorSubtract(r_newrefdef.vieworg, e->origin, modelorg);

	if (rotated)
	{
		vec3_t temp;
		vec3_t forward, right, up;

		VectorCopy(modelorg, temp);
		AngleVectors(e->angles, forward, right, up);
		modelorg[0] = DotProduct(temp, forward);
		modelorg[1] = -DotProduct(temp, right);
		modelorg[2] = DotProduct(temp, up);
	}

	qglPushMatrix();
	e->angles[0] = -e->angles[0];
	e->angles[2] = -e->angles[2];
	R_RotateForEntity(e);
	e->angles[0] = -e->angles[0];
	e->angles[2] = -e->angles[2];

	R_EnableMultitexture(true);
	R_SelectTexture(QGL_TEXTURE0);
	R_TexEnv(GL_REPLACE);
	R_SelectTexture(QGL_TEXTURE1);

	if (!gl_config.mtexcombine)
	{
		R_TexEnv(GL_REPLACE);
		R_SelectTexture(GL_TEXTURE1);

		if (gl_lightmap->value)
		{
			R_TexEnv(GL_REPLACE);
		}
		else
		{
			R_TexEnv(GL_MODULATE);
		}
	}
	else
	{
		R_TexEnv(GL_COMBINE_EXT);
		qglTexEnvi(GL_TEXTURE_ENV, GL_COMBINE_RGB_EXT, GL_REPLACE);
		qglTexEnvi(GL_TEXTURE_ENV, GL_SOURCE0_RGB_EXT, GL_TEXTURE);
		qglTexEnvi(GL_TEXTURE_ENV, GL_COMBINE_ALPHA_EXT, GL_REPLACE);
		qglTexEnvi(GL_TEXTURE_ENV, GL_SOURCE0_ALPHA_EXT, GL_TEXTURE);
		R_SelectTexture(GL_TEXTURE1);
		R_TexEnv(GL_COMBINE_EXT);

		if (gl_lightmap->value)
		{
			qglTexEnvi(GL_TEXTURE_ENV, GL_COMBINE_RGB_EXT, GL_REPLACE);
			qglTexEnvi(GL_TEXTURE_ENV, GL_SOURCE0_RGB_EXT, GL_TEXTURE);
			qglTexEnvi(GL_TEXTURE_ENV, GL_COMBINE_ALPHA_EXT, GL_REPLACE);
			qglTexEnvi(GL_TEXTURE_ENV, GL_SOURCE0_ALPHA_EXT, GL_TEXTURE);
		}
		else
		{
			qglTexEnvi(GL_TEXTURE_ENV, GL_COMBINE_RGB_EXT, GL_MODULATE);
			qglTexEnvi(GL_TEXTURE_ENV, GL_SOURCE0_RGB_EXT, GL_TEXTURE);
			qglTexEnvi(GL_TEXTURE_ENV, GL_SOURCE1_RGB_EXT, GL_PREVIOUS_EXT);
			qglTexEnvi(GL_TEXTURE_ENV, GL_COMBINE_ALPHA_EXT, GL_MODULATE);
			qglTexEnvi(GL_TEXTURE_ENV, GL_SOURCE0_ALPHA_EXT, GL_TEXTURE);
			qglTexEnvi(GL_TEXTURE_ENV, GL_SOURCE1_ALPHA_EXT, GL_PREVIOUS_EXT);
		}

		if (gl_overbrightbits->value)
		{
			qglTexEnvi(GL_TEXTURE_ENV, GL_RGB_SCALE_EXT,
					gl_overbrightbits->value);
		}
	}

	R_DrawInlineBModel();
	R_EnableMultitexture(false);

	qglPopMatrix();

	if (gl_zfix->value)
	{
		qglDisable(GL_POLYGON_OFFSET_FILL);
	}
}

void
R_RecursiveWorldNode(mnode_t *node)
{
	int c, side, sidebit;
	cplane_t *plane;
	msurface_t *surf, **mark;
	mleaf_t *pleaf;
	float dot;
	image_t *image;

	if (node->contents == CONTENTS_SOLID)
	{
		return; /* solid */
	}

	if (node->visframe != r_visframecount)
	{
		return;
	}

	if (R_CullBox(node->minmaxs, node->minmaxs + 3))
	{
		return;
	}

	/* if a leaf node, draw stuff */
	if (node->contents != -1)
	{
		pleaf = (mleaf_t *)node;

		/* check for door connected areas */
		if (r_newrefdef.areabits)
		{
			if (!(r_newrefdef.areabits[pleaf->area >> 3] & (1 << (pleaf->area & 7))))
			{
				return; /* not visible */
			}
		}

		mark = pleaf->firstmarksurface;
		c = pleaf->nummarksurfaces;

		if (c)
		{
			do
			{
				(*mark)->visframe = r_framecount;
				mark++;
			}
			while (--c);
		}

		return;
	}

	/* node is just a decision point, so go down the apropriate
	   sides find which side of the node we are on */
	plane = node->plane;

	switch (plane->type)
	{
		case PLANE_X:
			dot = modelorg[0] - plane->dist;
			break;
		case PLANE_Y:
			dot = modelorg[1] - plane->dist;
			break;
		case PLANE_Z:
			dot = modelorg[2] - plane->dist;
			break;
		default:
			dot = DotProduct(modelorg, plane->normal) - plane->dist;
			break;
	}

	if (dot >= 0)
	{
		side = 0;
		sidebit = 0;
	}
	else
	{
		side = 1;
		sidebit = SURF_PLANEBACK;
	}

	/* recurse down the children, front side first */
	R_RecursiveWorldNode(node->children[side]);

	/* draw stuff */
	for (c = node->numsurfaces,
		 surf = r_worldmodel->surfaces + node->firstsurface;
		 c; c--, surf++)
	{
		if (surf->visframe != r_framecount)
		{
			continue;
		}

		if ((surf->flags & SURF_PLANEBACK) != sidebit)
		{
			continue; /* wrong side */
		}

		if (surf->texinfo->flags & SURF_SKY)
		{
			/* just adds to visible sky bounds */
			R_AddSkySurface(surf);
		}
		else if (surf->texinfo->flags & (SURF_TRANS33 | SURF_TRANS66))
		{
			/* add to the translucent chain */
			surf->texturechain = r_alpha_surfaces;
			r_alpha_surfaces = surf;
		}
		else
		{
			if (qglMTexCoord2fSGIS && !(surf->flags & SURF_DRAWTURB))
			{
				R_RenderLightmappedPoly(surf);
			}
			else
			{
				/* the polygon is visible, so add it to the texture sorted chain */
				image = R_TextureAnimation(surf->texinfo);
				surf->texturechain = image->texturechain;
				image->texturechain = surf;
			}
		}
	}

	/* recurse down the back side */
	R_RecursiveWorldNode(node->children[!side]);
}

void
R_DrawWorld(void)
{
	entity_t ent;

	if (!gl_drawworld->value)
	{
		return;
	}

	if (r_newrefdef.rdflags & RDF_NOWORLDMODEL)
	{
		return;
	}

	currentmodel = r_worldmodel;

	VectorCopy(r_newrefdef.vieworg, modelorg);

	/* auto cycle the world frame for texture animation */
	memset(&ent, 0, sizeof(ent));
	ent.frame = (int)(r_newrefdef.time * 2);
	currententity = &ent;

	gl_state.currenttextures[0] = gl_state.currenttextures[1] = -1;

	qglColor3f(1, 1, 1);
	memset(gl_lms.lightmap_surfaces, 0, sizeof(gl_lms.lightmap_surfaces));
	R_ClearSkyBox();

	if (qglMTexCoord2fSGIS)
	{
		R_EnableMultitexture(true);

		R_SelectTexture(QGL_TEXTURE0);
		R_TexEnv(GL_REPLACE);
		R_SelectTexture(QGL_TEXTURE1);

		if (!gl_config.mtexcombine)
		{
			R_TexEnv(GL_REPLACE);
			R_SelectTexture(GL_TEXTURE1);

			if (gl_lightmap->value)
			{
				R_TexEnv(GL_REPLACE);
			}
			else
			{
				R_TexEnv(GL_MODULATE);
			}
		}
		else
		{
			R_TexEnv(GL_COMBINE_EXT);
			qglTexEnvi(GL_TEXTURE_ENV, GL_COMBINE_RGB_EXT, GL_REPLACE);
			qglTexEnvi(GL_TEXTURE_ENV, GL_SOURCE0_RGB_EXT, GL_TEXTURE);
			qglTexEnvi(GL_TEXTURE_ENV, GL_COMBINE_ALPHA_EXT, GL_REPLACE);
			qglTexEnvi(GL_TEXTURE_ENV, GL_SOURCE0_ALPHA_EXT, GL_TEXTURE);
			R_SelectTexture(GL_TEXTURE1);
			R_TexEnv(GL_COMBINE_EXT);

			if (gl_lightmap->value)
			{
				qglTexEnvi(GL_TEXTURE_ENV, GL_COMBINE_RGB_EXT, GL_REPLACE);
				qglTexEnvi(GL_TEXTURE_ENV, GL_SOURCE0_RGB_EXT, GL_TEXTURE);
				qglTexEnvi(GL_TEXTURE_ENV, GL_COMBINE_ALPHA_EXT, GL_REPLACE);
				qglTexEnvi(GL_TEXTURE_ENV, GL_SOURCE0_ALPHA_EXT, GL_TEXTURE);
			}
			else
			{
				qglTexEnvi(GL_TEXTURE_ENV, GL_COMBINE_RGB_EXT, GL_MODULATE);
				qglTexEnvi(GL_TEXTURE_ENV, GL_SOURCE0_RGB_EXT, GL_TEXTURE);
				qglTexEnvi(GL_TEXTURE_ENV, GL_SOURCE1_RGB_EXT, GL_PREVIOUS_EXT);
				qglTexEnvi(GL_TEXTURE_ENV, GL_COMBINE_ALPHA_EXT, GL_MODULATE);
				qglTexEnvi(GL_TEXTURE_ENV, GL_SOURCE0_ALPHA_EXT, GL_TEXTURE);
				qglTexEnvi(GL_TEXTURE_ENV, GL_SOURCE1_ALPHA_EXT, GL_PREVIOUS_EXT);
			}

			if (gl_overbrightbits->value)
			{
				qglTexEnvi(GL_TEXTURE_ENV, GL_RGB_SCALE_EXT, gl_overbrightbits->value);
			}
		}

		R_RecursiveWorldNode(r_worldmodel->nodes);
		/* RecursiveWorldNode emitted lots of mtex draws into the
		 * buffer; drain before flipping multitex off. */
		R_ApplyGLBuffer();
		R_EnableMultitexture(false);
	}
	else
	{
		R_RecursiveWorldNode(r_worldmodel->nodes);
	}

	R_DrawTextureChains();
	R_BlendLightmaps();
	R_DrawSkyBox();
	R_DrawTriangleOutlines();

	currententity = NULL;
}

/*
 * Mark the leaves and nodes that are 
 * in the PVS for the current cluster
 */
void
R_MarkLeaves(void)
{
	byte *vis;
	byte fatvis[MAX_MAP_LEAFS / 8];
	mnode_t *node;
	int i, c;
	mleaf_t *leaf;
	int cluster;

	if ((r_oldviewcluster == r_viewcluster) &&
		(r_oldviewcluster2 == r_viewcluster2) && 
		!gl_novis->value &&
		(r_viewcluster != -1))
	{
		return;
	}

	/* development aid to let you run around 
	   and see exactly where the pvs ends */
	if (gl_lockpvs->value)
	{
		return;
	}

	r_visframecount++;
	r_oldviewcluster = r_viewcluster;
	r_oldviewcluster2 = r_viewcluster2;

	if (gl_novis->value || (r_viewcluster == -1) || !r_worldmodel->vis)
	{
		/* mark everything */
		for (i = 0; i < r_worldmodel->numleafs; i++)
		{
			r_worldmodel->leafs[i].visframe = r_visframecount;
		}

		for (i = 0; i < r_worldmodel->numnodes; i++)
		{
			r_worldmodel->nodes[i].visframe = r_visframecount;
		}

		return;
	}

	vis = Mod_ClusterPVS(r_viewcluster, r_worldmodel);

	/* may have to combine two clusters because of solid water boundaries */
	if (r_viewcluster2 != r_viewcluster)
	{
		memcpy(fatvis, vis, (r_worldmodel->numleafs + 7) / 8);
		vis = Mod_ClusterPVS(r_viewcluster2, r_worldmodel);
		c = (r_worldmodel->numleafs + 31) / 32;

		for (i = 0; i < c; i++)
		{
			((int *)fatvis)[i] |= ((int *)vis)[i];
		}

		vis = fatvis;
	}

	for (i = 0, leaf = r_worldmodel->leafs;
		 i < r_worldmodel->numleafs;
		 i++, leaf++)
	{
		cluster = leaf->cluster;

		if (cluster == -1)
		{
			continue;
		}

		if (vis[cluster >> 3] & (1 << (cluster & 7)))
		{
			node = (mnode_t *)leaf;

			do
			{
				if (node->visframe == r_visframecount)
				{
					break;
				}

				node->visframe = r_visframecount;
				node = node->parent;
			}
			while (node);
		}
	}
}

