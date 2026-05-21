/*
 * Copyright (C) 1997-2001 Id Software, Inc.
 * Copyright (C) 2024      Jaime Moreira  (group-draw concept)
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
 * Group-draw buffer — accumulates many surfaces' worth of vertex / texture
 * coord / index data into a single batch, emits one qglDrawElements per
 * batch. Massive driver-overhead reduction on 1999-era fixed-function
 * GPUs (Rage 128, GeForce2 MX) where each immediate-mode call carries
 * disproportionate cost.
 *
 * Ported from yquake2-latest's gl1_buffer.c (Jaime Moreira, 2024) and
 * trimmed for the 5.11 baseline: no lightmapcopies, no GLES path, no
 * alias-shell buffered path (those keep immediate-mode for now), no GL
 * gamma (Phase B #5 — deferred), no overbrightbits warpsurf hack-on-hack.
 *
 * The buffer flushes-on-state-change via R_UpdateGLBuffer, which is the
 * usual call site at the start of each batched surface. A final
 * R_ApplyGLBuffer at the end of the dispatch loop drains the last batch.
 *
 * =======================================================================
 */

#include "header/local.h"

glbuffer_t gl_buf;

/* Mutable cursors into the index/vertex arrays during a batch build.
 * Kept module-static — outside callers use the macros (which mutate
 * gl_buf.vt/tx/cl directly) or the buffer functions below. */
static GLushort vtx_ptr;  /* number of vertices appended so far */
static GLushort idx_ptr;  /* number of indices written so far */

#define GLBUFFER_RESET   do { \
	vtx_ptr = 0; idx_ptr = 0; \
	gl_buf.vt = 0; gl_buf.tx = 0; gl_buf.cl = 0; \
} while (0)

void
R_ResetGLBuffer(void)
{
	GLBUFFER_RESET;
}

/*
 * Emit the accumulated batch as one qglDrawElements call, then clear
 * the buffer. Safe to call on an empty buffer — does nothing.
 *
 * Per-batch GL state setup depends on gl_buf.type (singletex / mtex /
 * alpha / 2d). For the alias and flash/shadow types we set the few
 * specific bits, otherwise default to the most common surface-render
 * configuration.
 */
void
R_ApplyGLBuffer(void)
{
	GLint vtx_size;
	qboolean texture, mtex, alpha, color;

	if (vtx_ptr == 0 || idx_ptr == 0)
	{
		return;
	}

	/* Defaults: 3D xyz, single texture, no per-vertex color. */
	vtx_size = 3;
	texture = true;
	mtex = false;
	alpha = false;
	color = false;

	switch (gl_buf.type)
	{
		case buf_2d:
			vtx_size = 2;
			break;
		case buf_mtex:
			mtex = true;
			break;
		case buf_alpha:
			alpha = true;
			break;
		case buf_alias:
		case buf_flash:
			color = true;
			break;
		case buf_shadow:
			texture = false;
			break;
		case buf_singletex:
		default:
			break;
	}

	if (mtex)
	{
		/* DO NOT call R_EnableMultitexture(true) here — that resets
		 * TMU1's TexEnv to GL_REPLACE, destroying the GL_COMBINE_EXT
		 * combiner setup R_DrawWorld put in place before
		 * R_RecursiveWorldNode. Visual bug: walls render as overbright
		 * lightmap-only (with OBB4 → flat yellow/beige).
		 *
		 * Multitex is enabled by R_DrawWorld for the entire BSP walk
		 * + drain; we just need to bind the two textures the batch
		 * needs. The outer code disables multitex when the buffer
		 * type transitions to singletex. */
		R_MBind(QGL_TEXTURE1, gl_state.lightmap_textures + gl_buf.texture[1]);
		R_MBind(QGL_TEXTURE0, gl_buf.texture[0]);
	}
	else if (texture)
	{
		R_Bind(gl_buf.texture[0]);
	}

	if (alpha)
	{
		/* alpha-blended surfaces are pre-scaled in intensity; scale
		 * back via vertex color rather than per-vertex stored color */
		qglColor4f(gl_state.inverse_intensity,
				gl_state.inverse_intensity,
				gl_state.inverse_intensity,
				gl_buf.alpha);
	}

	qglEnableClientState(GL_VERTEX_ARRAY);
	qglVertexPointer(vtx_size, GL_FLOAT, 0, gl_buf.vtx);

	if (texture)
	{
		qglEnableClientState(GL_TEXTURE_COORD_ARRAY);
		qglTexCoordPointer(2, GL_FLOAT, 0, gl_buf.tex[0]);

		if (mtex)
		{
			/* TMU1 lightmap coords — must enable on the second TMU. */
			qglClientActiveTextureARB(QGL_TEXTURE1);
			qglEnableClientState(GL_TEXTURE_COORD_ARRAY);
			qglTexCoordPointer(2, GL_FLOAT, 0, gl_buf.tex[1]);
			qglClientActiveTextureARB(QGL_TEXTURE0);
		}
	}

	if (color)
	{
		qglEnableClientState(GL_COLOR_ARRAY);
		qglColorPointer(4, GL_UNSIGNED_BYTE, 0, gl_buf.clr);
	}

	qglDrawElements(GL_TRIANGLES, idx_ptr, GL_UNSIGNED_SHORT, gl_buf.idx);

	if (color)
	{
		qglDisableClientState(GL_COLOR_ARRAY);
	}

	if (texture)
	{
		if (mtex)
		{
			qglClientActiveTextureARB(QGL_TEXTURE1);
			qglDisableClientState(GL_TEXTURE_COORD_ARRAY);
			qglClientActiveTextureARB(QGL_TEXTURE0);
		}
		qglDisableClientState(GL_TEXTURE_COORD_ARRAY);
	}

	qglDisableClientState(GL_VERTEX_ARRAY);

	/* Symmetric with the no-toggle above: do NOT call
	 * R_EnableMultitexture(false) on mtex flush exit. The outer code
	 * (R_DrawWorld, R_DrawInlineBModel) owns the multitex enable
	 * lifecycle and disables it explicitly when the BSP walk is done.
	 * Toggling here would force-disable mtex mid-walk if a single batch
	 * happened to flush before the walk completes (e.g. on a state
	 * change between two adjacent surfaces). */

	GLBUFFER_RESET;
}

/*
 * Update the buffer's current batch state. If the new state differs
 * from the current pending batch, the pending batch is flushed first
 * (so we never mix textures / modes within a single glDrawElements).
 * This is the usual call site at the start of each surface's draw.
 */
void
R_UpdateGLBuffer(buffered_draw_t type, int colortex, int lighttex,
		int flags, float alpha)
{
	if (gl_buf.type != type ||
		gl_buf.texture[0] != colortex ||
		(type == buf_mtex && gl_buf.texture[1] != lighttex) ||
		((type == buf_singletex || type == buf_alias) && gl_buf.flags != flags) ||
		(type == buf_alpha && gl_buf.alpha != alpha))
	{
		R_ApplyGLBuffer();

		gl_buf.type = type;
		gl_buf.texture[0] = colortex;
		gl_buf.texture[1] = lighttex;
		gl_buf.flags = flags;
		gl_buf.alpha = alpha;
	}
}

/*
 * Pre-write triangulated indices for the next `vertices_num` vertices
 * about to be appended via GLBUFFER_VERTEX. Caller specifies the source
 * primitive (typically GL_TRIANGLE_FAN for Q2 surface polys, occasionally
 * GL_TRIANGLE_STRIP for sky/flash). Flushes the buffer first if appending
 * would overflow MAX_VERTICES / MAX_INDICES.
 *
 * After this call the caller MUST emit exactly `vertices_num`
 * GLBUFFER_VERTEX (and matching GLBUFFER_SINGLETEX/MULTITEX/COLOR if
 * applicable) calls. Anything less leaves the buffer in an inconsistent
 * state on the next flush.
 */
void
R_SetBufferIndices(GLenum primitive, GLuint vertices_num)
{
	GLuint i;

	if (vertices_num < 3)
	{
		return;
	}

	if (vtx_ptr + vertices_num >= MAX_VERTICES ||
		idx_ptr + ((vertices_num - 2) * 3) >= MAX_INDICES)
	{
		R_ApplyGLBuffer();
	}

	switch (primitive)
	{
		case GL_TRIANGLE_FAN:
			for (i = 0; i < vertices_num - 2; i++)
			{
				gl_buf.idx[idx_ptr]     = vtx_ptr;
				gl_buf.idx[idx_ptr + 1] = vtx_ptr + i + 1;
				gl_buf.idx[idx_ptr + 2] = vtx_ptr + i + 2;
				idx_ptr += 3;
			}
			break;

		case GL_TRIANGLE_STRIP:
			for (i = 0; i < vertices_num - 2; i++)
			{
				if ((i & 1) == 0)
				{
					gl_buf.idx[idx_ptr]     = vtx_ptr + i;
					gl_buf.idx[idx_ptr + 1] = vtx_ptr + i + 1;
					gl_buf.idx[idx_ptr + 2] = vtx_ptr + i + 2;
				}
				else
				{
					gl_buf.idx[idx_ptr]     = vtx_ptr + i + 2;
					gl_buf.idx[idx_ptr + 1] = vtx_ptr + i + 1;
					gl_buf.idx[idx_ptr + 2] = vtx_ptr + i;
				}
				idx_ptr += 3;
			}
			break;

		default:
			/* Unsupported primitive — drop silently; the caller's
			 * subsequent GLBUFFER_VERTEX calls will land in vtx[] but
			 * no idx[] entries will reference them, so the next
			 * R_ApplyGLBuffer is harmless. */
			return;
	}

	vtx_ptr += vertices_num;
}
