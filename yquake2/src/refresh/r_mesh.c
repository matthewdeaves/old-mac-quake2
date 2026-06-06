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
 * Mesh handling
 *
 * =======================================================================
 */

#include "header/local.h"

/* yquake2-ppc — AltiVec R_LerpVerts attempt v2. Build with the
 * aligned-stack-load pattern instead of the (vector float){a,b,c,d}
 * literal that produced warped alias models on the v1 attempt (see
 * MISTAKES.md 2026-05-23). G3 (no -maltivec) gets the scalar path. */
#ifdef __ALTIVEC__
#include <altivec.h>
#endif

#define NUMVERTEXNORMALS 162
#define SHADEDOT_QUANT 16

float r_avertexnormals[NUMVERTEXNORMALS][3] = {
#include "constants/anorms.h"
};

/* precalculated dot products for quantized angles */
float r_avertexnormal_dots[SHADEDOT_QUANT][256] =
#include "constants/anormtab.h"
;

typedef float vec4_t[4];
/* Tier 1.3 — s_lerped must be 16-byte aligned for vec_st in the
 * AltiVec R_LerpVerts path. `typedef float vec4_t[4]` only gives
 * 4-byte alignment by default (the element's alignment), and `vec_st`
 * silently masks the bottom 4 bits of its address — without this
 * attribute, 12 of every 16 vertex writes land on wrong addresses,
 * producing warped alias-model geometry. Scalar path doesn't care. */
static vec4_t s_lerped[MAX_VERTS] __attribute__((aligned(16)));
vec3_t shadevector;
float shadelight[3];
float *shadedots = r_avertexnormal_dots[0];
extern vec3_t lightspot;
extern qboolean have_stencil;

/* Soft round drop-shadow texture (decals/shadow.tga) used by the
 * non-stencil blob-shadow path. Loaded at registration by
 * R_LoadShadowImage(); NULL means fall back to the projected shadow. */
image_t *r_shadow_texture = NULL;

void
R_LoadShadowImage(void)
{
	r_shadow_texture = R_FindImage("decals/shadow.tga", it_sprite);

	if (r_shadow_texture)
	{
		/* Clamp so the transparent rim never wraps the opaque center. */
		R_Bind(r_shadow_texture->texnum);
		qglTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
		qglTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	}
}

void
R_LerpVerts(int nverts, dtrivertx_t *v, dtrivertx_t *ov,
		dtrivertx_t *verts, float *lerp, float move[3],
		float frontv[3], float backv[3])
{
	int i;
	qboolean shell = (currententity->flags &
		(RF_SHELL_RED | RF_SHELL_GREEN |
		 RF_SHELL_BLUE | RF_SHELL_DOUBLE |
		 RF_SHELL_HALF_DAM)) != 0;

#ifdef __ALTIVEC__
	/* v2 AltiVec — aligned-stack-load pattern. v1 used `(vector
	 * float){a, b, c, d}` literal with per-lane (float)byte
	 * conversions; gcc-4.0 produced wrong lane-insertion code under
	 * some conditions, producing warped alias models. v2 builds the
	 * lane values into an aligned float[4] then `vec_ld`s the whole
	 * 16 bytes — gcc-4.0 generates straight-line scalar stores into
	 * the buffer followed by a real `lvx`, which is correct by
	 * construction. */
	{
		float __attribute__((aligned(16))) buf_move[4]   = {move[0],   move[1],   move[2],   0.0f};
		float __attribute__((aligned(16))) buf_backv[4]  = {backv[0],  backv[1],  backv[2],  0.0f};
		float __attribute__((aligned(16))) buf_frontv[4] = {frontv[0], frontv[1], frontv[2], 0.0f};
		vector float vmove   = vec_ld(0, buf_move);
		vector float vbackv  = vec_ld(0, buf_backv);
		vector float vfrontv = vec_ld(0, buf_frontv);

		if (shell)
		{
			for (i = 0; i < nverts; i++, v++, ov++, lerp += 4)
			{
				float *normal = r_avertexnormals[verts[i].lightnormalindex];
				float __attribute__((aligned(16))) buf_ov[4]   = {(float)ov->v[0], (float)ov->v[1], (float)ov->v[2], 0.0f};
				float __attribute__((aligned(16))) buf_v[4]    = {(float)v->v[0],  (float)v->v[1],  (float)v->v[2],  0.0f};
				float __attribute__((aligned(16))) buf_norm[4] = {
					normal[0] * POWERSUIT_SCALE,
					normal[1] * POWERSUIT_SCALE,
					normal[2] * POWERSUIT_SCALE,
					0.0f };
				vector float vov   = vec_ld(0, buf_ov);
				vector float vv_   = vec_ld(0, buf_v);
				vector float vnorm = vec_ld(0, buf_norm);

				vector float r = vec_madd(vov, vbackv, vmove);
				r = vec_madd(vv_, vfrontv, r);
				r = vec_add(r, vnorm);
				vec_st(r, 0, lerp);
			}
		}
		else
		{
			for (i = 0; i < nverts; i++, v++, ov++, lerp += 4)
			{
				float __attribute__((aligned(16))) buf_ov[4] = {(float)ov->v[0], (float)ov->v[1], (float)ov->v[2], 0.0f};
				float __attribute__((aligned(16))) buf_v[4]  = {(float)v->v[0],  (float)v->v[1],  (float)v->v[2],  0.0f};
				vector float vov = vec_ld(0, buf_ov);
				vector float vv_ = vec_ld(0, buf_v);

				vector float r = vec_madd(vov, vbackv, vmove);
				r = vec_madd(vv_, vfrontv, r);
				vec_st(r, 0, lerp);
			}
		}
	}
#else
	if (shell)
	{
		for (i = 0; i < nverts; i++, v++, ov++, lerp += 4)
		{
			float *normal = r_avertexnormals[verts[i].lightnormalindex];

			lerp[0] = move[0] + ov->v[0] * backv[0] + v->v[0] * frontv[0] +
					  normal[0] * POWERSUIT_SCALE;
			lerp[1] = move[1] + ov->v[1] * backv[1] + v->v[1] * frontv[1] +
					  normal[1] * POWERSUIT_SCALE;
			lerp[2] = move[2] + ov->v[2] * backv[2] + v->v[2] * frontv[2] +
					  normal[2] * POWERSUIT_SCALE;
			lerp[3] = 0;
		}
	}
	else
	{
		for (i = 0; i < nverts; i++, v++, ov++, lerp += 4)
		{
			lerp[0] = move[0] + ov->v[0] * backv[0] + v->v[0] * frontv[0];
			lerp[1] = move[1] + ov->v[1] * backv[1] + v->v[1] * frontv[1];
			lerp[2] = move[2] + ov->v[2] * backv[2] + v->v[2] * frontv[2];
			lerp[3] = 0;
		}
	}
#endif /* __ALTIVEC__ */
}

/*
 * Interpolates between two frames and origins
 */
void
R_DrawAliasFrameLerp(dmdl_t *paliashdr, float backlerp)
{
	float l;
	daliasframe_t *frame, *oldframe;
	dtrivertx_t *v, *ov, *verts;
	int *order;
	int count;
	float frontlerp;
	float alpha;
	qboolean shell_glow = false;   /* RF_SHELL sphere-map glow active (gl_glows) */

	/* Group-draw drain: per-alias-model immediate-mode emit ahead. */
	R_ApplyGLBuffer();
	vec3_t move, delta, vectors[3];
	vec3_t frontv, backv;
	int i;
	int index_xyz;
	float *lerp;

	frame = (daliasframe_t *)((byte *)paliashdr + paliashdr->ofs_frames
							  + currententity->frame * paliashdr->framesize);
	verts = v = frame->verts;

	oldframe = (daliasframe_t *)((byte *)paliashdr + paliashdr->ofs_frames
				+ currententity->oldframe * paliashdr->framesize);
	ov = oldframe->verts;

	order = (int *)((byte *)paliashdr + paliashdr->ofs_glcmds);

	if (currententity->flags & RF_TRANSLUCENT)
	{
		alpha = currententity->alpha;
	}
	else
	{
		alpha = 1.0;
	}

	if (currententity->flags &
		(RF_SHELL_RED | RF_SHELL_GREEN | RF_SHELL_BLUE | RF_SHELL_DOUBLE |
		 RF_SHELL_HALF_DAM))
	{
		if (gl_glows->value && r_shelltexture)
		{
			/* Energy-shell glow: sphere-map a radial highlight onto the
			 * shell silhouette instead of drawing it as a flat colour.
			 * The texture stays bound and is MODULATEd by the shell
			 * colour set in qglColor; GL_SPHERE_MAP texgen generates the
			 * coords from the per-vertex normals emitted in the draw loop
			 * below, so the hotspot tracks the view and shimmers. */
			shell_glow = true;
			R_Bind(r_shelltexture->texnum);
			R_TexEnv(GL_MODULATE);
			qglTexGeni(GL_S, GL_TEXTURE_GEN_MODE, GL_SPHERE_MAP);
			qglTexGeni(GL_T, GL_TEXTURE_GEN_MODE, GL_SPHERE_MAP);
			qglEnable(GL_TEXTURE_GEN_S);
			qglEnable(GL_TEXTURE_GEN_T);
		}
		else
		{
			qglDisable(GL_TEXTURE_2D);
		}
	}

	frontlerp = 1.0 - backlerp;

	/* move should be the delta back to the previous frame * backlerp */
	VectorSubtract(currententity->oldorigin, currententity->origin, delta);
	AngleVectors(currententity->angles, vectors[0], vectors[1], vectors[2]);

	move[0] = DotProduct(delta, vectors[0]); /* forward */
	move[1] = -DotProduct(delta, vectors[1]); /* left */
	move[2] = DotProduct(delta, vectors[2]); /* up */

	VectorAdd(move, oldframe->translate, move);

	for (i = 0; i < 3; i++)
	{
		move[i] = backlerp * move[i] + frontlerp * frame->translate[i];
	}

	for (i = 0; i < 3; i++)
	{
		frontv[i] = frontlerp * frame->scale[i];
		backv[i] = backlerp * oldframe->scale[i];
	}

	lerp = s_lerped[0];

	R_LerpVerts(paliashdr->num_xyz, v, ov, verts, lerp, move, frontv, backv);

	if (gl_vertex_arrays->value)
	{
		float colorArray[MAX_VERTS * 4];

		qglEnableClientState(GL_VERTEX_ARRAY);
		qglVertexPointer(3, GL_FLOAT, 16, s_lerped);

		if (currententity->flags &
			(RF_SHELL_RED | RF_SHELL_GREEN | RF_SHELL_BLUE |
			 RF_SHELL_DOUBLE | RF_SHELL_HALF_DAM))
		{
			qglColor4f(shadelight[0], shadelight[1], shadelight[2], alpha);
		}
		else
		{
			qglEnableClientState(GL_COLOR_ARRAY);
			qglColorPointer(3, GL_FLOAT, 0, colorArray);

			/* pre light everything */
			for (i = 0; i < paliashdr->num_xyz; i++)
			{
				l = shadedots[verts[i].lightnormalindex];

				colorArray[i * 3 + 0] = l * shadelight[0];
				colorArray[i * 3 + 1] = l * shadelight[1];
				colorArray[i * 3 + 2] = l * shadelight[2];
			}
		}

		if (qglLockArraysEXT != 0)
		{
			qglLockArraysEXT(0, paliashdr->num_xyz);
		}

		while (1)
		{
			/* get the vertex count and primitive type */
			count = *order++;

			if (!count)
			{
				break; /* done */
			}

			if (count < 0)
			{
				count = -count;
				qglBegin(GL_TRIANGLE_FAN);
			}
			else
			{
				qglBegin(GL_TRIANGLE_STRIP);
			}

			if (currententity->flags &
				(RF_SHELL_RED | RF_SHELL_GREEN | RF_SHELL_BLUE |
				 RF_SHELL_DOUBLE |
				 RF_SHELL_HALF_DAM))
			{
				do
				{
					index_xyz = order[2];
					order += 3;

					qglVertex3fv(s_lerped[index_xyz]);
				}
				while (--count);
			}
			else
			{
				do
				{
					/* texture coordinates come from the draw list */
					qglTexCoord2f(((float *)order)[0], ((float *)order)[1]);
					index_xyz = order[2];

					order += 3;

					qglArrayElement(index_xyz);
				}
				while (--count);
			}

			qglEnd();
		}

		if (qglUnlockArraysEXT != 0)
		{
			qglUnlockArraysEXT();
		}
	}
	else
	{
		while (1)
		{
			/* get the vertex count and primitive type */
			count = *order++;

			if (!count)
			{
				break; /* done */
			}

			if (count < 0)
			{
				count = -count;
				qglBegin(GL_TRIANGLE_FAN);
			}
			else
			{
				qglBegin(GL_TRIANGLE_STRIP);
			}

			if (currententity->flags &
				(RF_SHELL_RED | RF_SHELL_GREEN | RF_SHELL_BLUE))
			{
				do
				{
					index_xyz = order[2];
					order += 3;

					qglColor4f(shadelight[0], shadelight[1],
							shadelight[2], alpha);
					if (shell_glow)
					{
						/* sphere-map texgen needs a live normal per vertex */
						qglNormal3fv(
							r_avertexnormals[verts[index_xyz].lightnormalindex]);
					}
					qglVertex3fv(s_lerped[index_xyz]);
				}
				while (--count);
			}
			else
			{
				do
				{
					/* texture coordinates come from the draw list */
					qglTexCoord2f(((float *)order)[0], ((float *)order)[1]);
					index_xyz = order[2];
					order += 3;

					/* normals and vertexes come from the frame list */
					l = shadedots[verts[index_xyz].lightnormalindex];

					qglColor4f(l * shadelight[0], l * shadelight[1],
							l * shadelight[2], alpha);
					qglVertex3fv(s_lerped[index_xyz]);
				}
				while (--count);
			}

			qglEnd();
		}
	}

	if (currententity->flags &
		(RF_SHELL_RED | RF_SHELL_GREEN | RF_SHELL_BLUE |
		 RF_SHELL_DOUBLE | RF_SHELL_HALF_DAM))
	{
		if (shell_glow)
		{
			/* texture stayed enabled in the glow path; just retire texgen
			 * so it cannot leak into world / other model draws */
			qglDisable(GL_TEXTURE_GEN_S);
			qglDisable(GL_TEXTURE_GEN_T);
		}
		else
		{
			qglEnable(GL_TEXTURE_2D);
		}
	}
}

void
R_DrawAliasShadow(dmdl_t *paliashdr, int posenum)
{
	int *order;
	vec3_t point;
	float height = 0, lheight;
	int count;

	/* Group-draw drain: per-shadow immediate-mode emit ahead. */
	R_ApplyGLBuffer();

	lheight = currententity->origin[2] - lightspot[2];
	order = (int *)((byte *)paliashdr + paliashdr->ofs_glcmds);
	height = -lheight + 0.1f;

	/* Non-stencil path: the per-triangle projected shadow overlaps itself
	 * and compounds at alpha 0.5 into dark blotches (the R9200/Tiger fleet
	 * can't afford the stencil mask that prevents this — 60% fps cost).
	 * Draw a single soft blob quad instead: clean, uniform, one draw. */
	if (!(have_stencil && gl_stencilshadow->value) && r_shadow_texture)
	{
		daliasframe_t *frame;
		float radius;

		frame = (daliasframe_t *)((byte *)paliashdr + paliashdr->ofs_frames
				+ posenum * paliashdr->framesize);

		/* Footprint radius from the frame's model-space bbox (byte verts
		 * span 0..255, scaled by frame->scale). Half the wider of X/Y. */
		radius = 0.5f * 255.0f * (frame->scale[0] > frame->scale[1]
				? frame->scale[0] : frame->scale[1]);
		if (radius < 4.0f)  { radius = 4.0f; }
		if (radius > 64.0f) { radius = 64.0f; }

		/* Draw one textured quad. Use GL_REPLACE so the texture colour
		 * and alpha are used directly — GL_MODULATE on this driver
		 * multiplies vertex (0,0,0,0.5) through the texture sample,
		 * collapsing the whole result to transparent black. The shadow
		 * texture is pre-baked RGBA (0,0,0,alpha@50%) so no vertex
		 * colour is needed. */
		qglColor4f(1.0f, 1.0f, 1.0f, 1.0f);  /* REPLACE ignores vert colour, but reset cleanly */
		qglEnable(GL_TEXTURE_2D);
		R_Bind(r_shadow_texture->texnum);
		R_TexEnv(GL_REPLACE);
		qglDepthMask(GL_FALSE);

		qglBegin(GL_QUADS);
		qglTexCoord2f(0.0f, 0.0f); qglVertex3f(-radius, -radius, height);
		qglTexCoord2f(1.0f, 0.0f); qglVertex3f( radius, -radius, height);
		qglTexCoord2f(1.0f, 1.0f); qglVertex3f( radius,  radius, height);
		qglTexCoord2f(0.0f, 1.0f); qglVertex3f(-radius,  radius, height);
		qglEnd();

		qglDepthMask(GL_TRUE);
		/* TexEnv stays GL_REPLACE — that was the state on entry. */
		return;
	}

	/* stencilbuffer shadows */
	if (have_stencil && gl_stencilshadow->value)
	{
		qglEnable(GL_STENCIL_TEST);
		qglStencilFunc(GL_EQUAL, 1, 2);
		qglStencilOp(GL_KEEP, GL_KEEP, GL_INCR);
	}

	while (1)
	{
		/* get the vertex count and primitive type */
		count = *order++;

		if (!count)
		{
			break; /* done */
		}

		if (count < 0)
		{
			count = -count;
			qglBegin(GL_TRIANGLE_FAN);
		}
		else
		{
			qglBegin(GL_TRIANGLE_STRIP);
		}

		do
		{
			/* normals and vertexes come from the frame list */
			memcpy(point, s_lerped[order[2]], sizeof(point));

			point[0] -= shadevector[0] * (point[2] + lheight);
			point[1] -= shadevector[1] * (point[2] + lheight);
			point[2] = height;
			qglVertex3fv(point);

			order += 3;
		}
		while (--count);

		qglEnd();
	}

	/* stencilbuffer shadows */
	if (have_stencil && gl_stencilshadow->value)
	{
		qglDisable(GL_STENCIL_TEST);
	}
}

static qboolean
R_CullAliasModel(vec3_t bbox[8], entity_t *e)
{
	int i;
	vec3_t mins, maxs;
	dmdl_t *paliashdr;
	vec3_t vectors[3];
	vec3_t thismins, oldmins, thismaxs, oldmaxs;
	daliasframe_t *pframe, *poldframe;
	vec3_t angles;

	paliashdr = (dmdl_t *)currentmodel->extradata;

	if ((e->frame >= paliashdr->num_frames) || (e->frame < 0))
	{
		ri.Con_Printf(PRINT_ALL, "R_CullAliasModel %s: no such frame %d\n",
				currentmodel->name, e->frame);
		e->frame = 0;
	}

	if ((e->oldframe >= paliashdr->num_frames) || (e->oldframe < 0))
	{
		ri.Con_Printf(PRINT_ALL, "R_CullAliasModel %s: no such oldframe %d\n",
				currentmodel->name, e->oldframe);
		e->oldframe = 0;
	}

	pframe = (daliasframe_t *)((byte *)paliashdr + paliashdr->ofs_frames +
			e->frame * paliashdr->framesize);

	poldframe = (daliasframe_t *)((byte *)paliashdr + paliashdr->ofs_frames +
			e->oldframe * paliashdr->framesize);

	/* compute axially aligned mins and maxs */
	if (pframe == poldframe)
	{
		for (i = 0; i < 3; i++)
		{
			mins[i] = pframe->translate[i];
			maxs[i] = mins[i] + pframe->scale[i] * 255;
		}
	}
	else
	{
		for (i = 0; i < 3; i++)
		{
			thismins[i] = pframe->translate[i];
			thismaxs[i] = thismins[i] + pframe->scale[i] * 255;

			oldmins[i] = poldframe->translate[i];
			oldmaxs[i] = oldmins[i] + poldframe->scale[i] * 255;

			if (thismins[i] < oldmins[i])
			{
				mins[i] = thismins[i];
			}
			else
			{
				mins[i] = oldmins[i];
			}

			if (thismaxs[i] > oldmaxs[i])
			{
				maxs[i] = thismaxs[i];
			}
			else
			{
				maxs[i] = oldmaxs[i];
			}
		}
	}

	/* compute a full bounding box */
	for (i = 0; i < 8; i++)
	{
		vec3_t tmp;

		if (i & 1)
		{
			tmp[0] = mins[0];
		}
		else
		{
			tmp[0] = maxs[0];
		}

		if (i & 2)
		{
			tmp[1] = mins[1];
		}
		else
		{
			tmp[1] = maxs[1];
		}

		if (i & 4)
		{
			tmp[2] = mins[2];
		}
		else
		{
			tmp[2] = maxs[2];
		}

		VectorCopy(tmp, bbox[i]);
	}

	/* rotate the bounding box */
	VectorCopy(e->angles, angles);
	angles[YAW] = -angles[YAW];
	AngleVectors(angles, vectors[0], vectors[1], vectors[2]);

	for (i = 0; i < 8; i++)
	{
		vec3_t tmp;

		VectorCopy(bbox[i], tmp);

		bbox[i][0] = DotProduct(vectors[0], tmp);
		bbox[i][1] = -DotProduct(vectors[1], tmp);
		bbox[i][2] = DotProduct(vectors[2], tmp);

		VectorAdd(e->origin, bbox[i], bbox[i]);
	}

	int p, f, aggregatemask = ~0;

	for (p = 0; p < 8; p++)
	{
		int mask = 0;

		for (f = 0; f < 4; f++)
		{
			float dp = DotProduct(frustum[f].normal, bbox[p]);

			if ((dp - frustum[f].dist) < 0)
			{
				mask |= (1 << f);
			}
		}

		aggregatemask &= mask;
	}

	if (aggregatemask)
	{
		return true;
	}

	return false;
}

void
R_DrawAliasModel(entity_t *e)
{
	int i;
	dmdl_t *paliashdr;
	float an;
	vec3_t bbox[8];
	image_t *skin;

	if (!(e->flags & RF_WEAPONMODEL))
	{
		if (R_CullAliasModel(bbox, e))
		{
			return;
		}
	}

	if (e->flags & RF_WEAPONMODEL)
	{
		if (gl_lefthand->value == 2)
		{
			return;
		}
	}

	paliashdr = (dmdl_t *)currentmodel->extradata;

	/* get lighting information */
	if (currententity->flags &
		(RF_SHELL_HALF_DAM | RF_SHELL_GREEN | RF_SHELL_RED |
		 RF_SHELL_BLUE | RF_SHELL_DOUBLE))
	{
		VectorClear(shadelight);

		if (currententity->flags & RF_SHELL_HALF_DAM)
		{
			shadelight[0] = 0.56;
			shadelight[1] = 0.59;
			shadelight[2] = 0.45;
		}

		if (currententity->flags & RF_SHELL_DOUBLE)
		{
			shadelight[0] = 0.9;
			shadelight[1] = 0.7;
		}

		if (currententity->flags & RF_SHELL_RED)
		{
			shadelight[0] = 1.0;
		}

		if (currententity->flags & RF_SHELL_GREEN)
		{
			shadelight[1] = 1.0;
		}

		if (currententity->flags & RF_SHELL_BLUE)
		{
			shadelight[2] = 1.0;
		}
	}
	else if (currententity->flags & RF_FULLBRIGHT)
	{
		for (i = 0; i < 3; i++)
		{
			shadelight[i] = 1.0;
		}
	}
	else
	{
		R_LightPoint(currententity->origin, shadelight);

		/* player lighting hack for communication back to server */
		if (currententity->flags & RF_WEAPONMODEL)
		{
			/* pick the greatest component, which should be
			   the same as the mono value returned by software */
			if (shadelight[0] > shadelight[1])
			{
				if (shadelight[0] > shadelight[2])
				{
					gl_lightlevel->value = 150 * shadelight[0];
				}
				else
				{
					gl_lightlevel->value = 150 * shadelight[2];
				}
			}
			else
			{
				if (shadelight[1] > shadelight[2])
				{
					gl_lightlevel->value = 150 * shadelight[1];
				}
				else
				{
					gl_lightlevel->value = 150 * shadelight[2];
				}
			}
		}
	}

	if (currententity->flags & RF_MINLIGHT)
	{
		for (i = 0; i < 3; i++)
		{
			if (shadelight[i] > 0.1)
			{
				break;
			}
		}

		if (i == 3)
		{
			shadelight[0] = 0.1;
			shadelight[1] = 0.1;
			shadelight[2] = 0.1;
		}
	}

	if (currententity->flags & RF_GLOW)
	{
		/* bonus items will pulse with time */
		float scale;
		float min;

		scale = 0.1 * sin(r_newrefdef.time * 7);

		for (i = 0; i < 3; i++)
		{
			min = shadelight[i] * 0.8;
			shadelight[i] += scale;

			if (shadelight[i] < min)
			{
				shadelight[i] = min;
			}
		}
	}

	/* ir goggles color override */
	if (r_newrefdef.rdflags & RDF_IRGOGGLES && currententity->flags &
		RF_IR_VISIBLE)
	{
		shadelight[0] = 1.0;
		shadelight[1] = 0.0;
		shadelight[2] = 0.0;
	}

	shadedots = r_avertexnormal_dots[((int)(currententity->angles[1] *
				(SHADEDOT_QUANT / 360.0))) & (SHADEDOT_QUANT - 1)];

	an = currententity->angles[1] / 180 * M_PI;
	shadevector[0] = cos(-an);
	shadevector[1] = sin(-an);
	shadevector[2] = 1;
	VectorNormalize(shadevector);

	/* locate the proper data */
	c_alias_polys += paliashdr->num_tris;

	/* draw all the triangles */
	if (currententity->flags & RF_DEPTHHACK)
	{
		/* hack the depth range to prevent view model from poking into walls */
		qglDepthRange(gldepthmin, gldepthmin + 0.3 * (gldepthmax - gldepthmin));
	}

	if ((currententity->flags & RF_WEAPONMODEL) && (gl_lefthand->value == 1.0F))
	{
		extern void R_MYgluPerspective(GLdouble fovy, GLdouble aspect,
				GLdouble zNear, GLdouble zFar);

		qglMatrixMode(GL_PROJECTION);
		qglPushMatrix();
		qglLoadIdentity();
		qglScalef(-1, 1, 1);
		R_MYgluPerspective(r_newrefdef.fov_y,
				(float)r_newrefdef.width / r_newrefdef.height,
				4, 4096);
		qglMatrixMode(GL_MODELVIEW);

		qglCullFace(GL_BACK);
	}

	qglPushMatrix();
	e->angles[PITCH] = -e->angles[PITCH];
	R_RotateForEntity(e);
	e->angles[PITCH] = -e->angles[PITCH];

	/* select skin */
	if (currententity->skin)
	{
		skin = currententity->skin; /* custom player skin */
	}
	else
	{
		if (currententity->skinnum >= MAX_MD2SKINS)
		{
			skin = currentmodel->skins[0];
		}
		else
		{
			skin = currentmodel->skins[currententity->skinnum];

			if (!skin)
			{
				skin = currentmodel->skins[0];
			}
		}
	}

	if (!skin)
	{
		skin = r_notexture; /* fallback... */
	}

	R_Bind(skin->texnum);

	/* draw it */
	qglShadeModel(GL_SMOOTH);

	R_TexEnv(GL_MODULATE);

	if (currententity->flags & RF_TRANSLUCENT)
	{
		qglEnable(GL_BLEND);
	}

	if ((currententity->frame >= paliashdr->num_frames) ||
		(currententity->frame < 0))
	{
		ri.Con_Printf(PRINT_ALL, "R_DrawAliasModel %s: no such frame %d\n",
				currentmodel->name, currententity->frame);
		currententity->frame = 0;
		currententity->oldframe = 0;
	}

	if ((currententity->oldframe >= paliashdr->num_frames) ||
		(currententity->oldframe < 0))
	{
		ri.Con_Printf(PRINT_ALL, "R_DrawAliasModel %s: no such oldframe %d\n",
				currentmodel->name, currententity->oldframe);
		currententity->frame = 0;
		currententity->oldframe = 0;
	}

	if (!gl_lerpmodels->value)
	{
		currententity->backlerp = 0;
	}

	R_DrawAliasFrameLerp(paliashdr, currententity->backlerp);

	R_TexEnv(GL_REPLACE);
	qglShadeModel(GL_FLAT);

	qglPopMatrix();

	if ((currententity->flags & RF_WEAPONMODEL) && (gl_lefthand->value == 1.0F))
	{
		qglMatrixMode(GL_PROJECTION);
		qglPopMatrix();
		qglMatrixMode(GL_MODELVIEW);
		qglCullFace(GL_FRONT);
	}

	if (currententity->flags & RF_TRANSLUCENT)
	{
		qglDisable(GL_BLEND);
	}

	if (currententity->flags & RF_DEPTHHACK)
	{
		qglDepthRange(gldepthmin, gldepthmax);
	}

	if (gl_shadows->value &&
		!(currententity->flags & (RF_TRANSLUCENT | RF_WEAPONMODEL | RF_NOSHADOW)))
	{
		qglPushMatrix();

		/* don't rotate shadows on ungodly axes */
		qglTranslatef(e->origin[0], e->origin[1], e->origin[2]);
		qglRotatef(e->angles[1], 0, 0, 1);

		qglDisable(GL_TEXTURE_2D);
		qglEnable(GL_BLEND);
		qglColor4f(0, 0, 0, 0.5);
		R_DrawAliasShadow(paliashdr, currententity->frame);
		qglEnable(GL_TEXTURE_2D);
		qglDisable(GL_BLEND);
		qglPopMatrix();
	}

	qglColor4f(1, 1, 1, 1);
}

