/*
 * r_decal.c — world-decal subsystem for yquake2 5.11 PPC port.
 *
 * Ported from KMQuake2's r_fragment.c (id Tech 2 derivative, GPLv2),
 * with the decal manager and rendering pulled in alongside the
 * fragment clipper so the whole subsystem lives renderer-side. The
 * client only sees one entry point (re.R_AddDecal). This keeps GL
 * state ownership inside the renderer where it belongs and avoids
 * adding multiple passthroughs to the refexport_t ABI.
 *
 * Fleet sizing: yosemite (R128 16 MB) is opted out via gl_decals 0
 * in autoexec-yosemite.cfg; sawtooth (GF2 MX, dlights already off)
 * limits to 8; mini-g4 / quicksilver / mini-intel run 32 by default;
 * imac-2019 (Polaris) goes up to 128.
 */

#include "header/local.h"

#define	SIDE_FRONT      0
#define	SIDE_BACK       1
#define	SIDE_ON         2
#define	ON_EPSILON      0.1

#define MAX_FRAGMENT_POINTS    128
#define MAX_FRAGMENT_PLANES    6

/* Storage caps. Vertex pool is 16× the decal slot count — typical
 * fragments are 3-12 verts each, so this gives us headroom without
 * a runtime allocation. */
#define MAX_DECALS         128
#define MAX_DECAL_VERTS    (MAX_DECALS * 16)

typedef struct {
	qboolean   inUse;
	float      time;            /* spawn timestamp */
	float      fadeStart;       /* time to start fading */
	float      fadeEnd;         /* time fully gone */
	image_t   *texture;
	int        firstPoint;      /* into r_decal_verts[] */
	int        numPoints;       /* total verts across all fragments */
	int        numFragments;
	int        fragOffsets[16]; /* per-fragment first-vert offsets */
	int        fragLens[16];    /* per-fragment vert counts */
	/* Texgen state, captured at spawn time so the draw pass can compute
	 * accurate texcoords (not approximated from fragment centroid).
	 * Without these, mismatched radii cause the alpha-faded edge of the
	 * decal texture to never reach the fragment boundary — producing a
	 * visible square outline on the wall. */
	vec3_t     origin;          /* impact point in world space */
	vec3_t     right;           /* basis: in-plane right vector */
	vec3_t     up;              /* basis: in-plane up vector */
	float      radius;          /* clip radius — texture maps [-r,+r] → [0,1] */
	float      rotCos;          /* per-decal in-plane rotation cos/sin */
	float      rotSin;          /* (random per spawn — breaks pattern repetition on walls) */
} r_decal_t;

static r_decal_t r_decals[MAX_DECALS];
static vec3_t    r_decal_verts[MAX_DECAL_VERTS];
static int       r_decal_next;   /* FIFO write head */
static int       r_decal_check;  /* recursion guard counter */

/* Fragment clipper working state. Local to the clip pass; gets reset
 * each R_MarkFragments call. */
static int             cm_numMarkPoints;
static int             cm_maxMarkPoints;
static vec3_t         *cm_markPoints;
static int             cm_numMarkFragments;
static int             cm_maxMarkFragments;
static markFragment_t *cm_markFragments;
static cplane_t        cm_markPlanes[MAX_FRAGMENT_PLANES];

/* Preloaded decal textures, one per DECAL_* type. Loaded by
 * R_LoadDecalTextures at R_BeginRegistration time. */
static image_t *r_decal_textures[4];

cvar_t *gl_decals;
cvar_t *gl_decal_max;
cvar_t *gl_decal_life;
cvar_t *gl_decal_fade;

static int
PlaneTypeForNormal(const vec3_t normal)
{
	if (normal[0] == 1.0f) return 0;
	if (normal[1] == 1.0f) return 1;
	if (normal[2] == 1.0f) return 2;
	return 3;
}

static float *
worldVert(int i, msurface_t *surf)
{
	int e = r_worldmodel->surfedges[surf->firstedge + i];
	if (e >= 0)
	{
		return &r_worldmodel->vertexes[r_worldmodel->edges[e].v[0]].position[0];
	}
	return &r_worldmodel->vertexes[r_worldmodel->edges[-e].v[1]].position[0];
}

static void
R_ClipFragment(int numPoints, vec3_t points, int stage, markFragment_t *mf)
{
	int       i, f;
	float    *p;
	qboolean  frontSide;
	vec3_t    front[MAX_FRAGMENT_POINTS];
	float     dist, dists[MAX_FRAGMENT_POINTS];
	int       sides[MAX_FRAGMENT_POINTS];
	cplane_t *plane;

	if (numPoints > MAX_FRAGMENT_POINTS - 2)
	{
		return;  /* silent drop — better than tearing the map */
	}

	if (stage == MAX_FRAGMENT_PLANES)
	{
		if (numPoints > 2)
		{
			mf->numPoints = numPoints;
			mf->firstPoint = cm_numMarkPoints;

			if (cm_numMarkPoints + numPoints > cm_maxMarkPoints)
			{
				numPoints = cm_maxMarkPoints - cm_numMarkPoints;
			}

			for (i = 0, p = points; i < numPoints; i++, p += 3)
			{
				VectorCopy(p, cm_markPoints[cm_numMarkPoints + i]);
			}

			cm_numMarkPoints += numPoints;
		}
		return;
	}

	frontSide = false;
	plane = &cm_markPlanes[stage];
	for (i = 0, p = points; i < numPoints; i++, p += 3)
	{
		if (plane->type < 3)
		{
			dists[i] = dist = p[plane->type] - plane->dist;
		}
		else
		{
			dists[i] = dist = DotProduct(p, plane->normal) - plane->dist;
		}

		if (dist > ON_EPSILON)
		{
			frontSide = true;
			sides[i] = SIDE_FRONT;
		}
		else if (dist < -ON_EPSILON)
		{
			sides[i] = SIDE_BACK;
		}
		else
		{
			sides[i] = SIDE_ON;
		}
	}

	if (!frontSide)
	{
		return;
	}

	dists[i] = dists[0];
	sides[i] = sides[0];
	VectorCopy(points, (points + (i * 3)));

	f = 0;
	for (i = 0, p = points; i < numPoints; i++, p += 3)
	{
		switch (sides[i])
		{
			case SIDE_FRONT:
				VectorCopy(p, front[f]);
				f++;
				break;
			case SIDE_BACK:
				break;
			case SIDE_ON:
				VectorCopy(p, front[f]);
				f++;
				break;
		}

		if (sides[i] == SIDE_ON || sides[i + 1] == SIDE_ON || sides[i + 1] == sides[i])
		{
			continue;
		}

		dist = dists[i] / (dists[i] - dists[i + 1]);
		front[f][0] = p[0] + (p[3] - p[0]) * dist;
		front[f][1] = p[1] + (p[4] - p[1]) * dist;
		front[f][2] = p[2] + (p[5] - p[2]) * dist;
		f++;
	}

	R_ClipFragment(f, front[0], stage + 1, mf);
}

static void
R_ClipFragmentToSurface(msurface_t *surf, const vec3_t normal, mnode_t *node)
{
	qboolean planeback = (surf->flags & SURF_PLANEBACK) != 0;
	int      i;
	float    d;
	vec3_t   points[MAX_FRAGMENT_POINTS];
	markFragment_t *mf;

	if (cm_numMarkPoints >= cm_maxMarkPoints ||
	    cm_numMarkFragments >= cm_maxMarkFragments)
	{
		return;
	}

	d = DotProduct(normal, surf->plane->normal);
	if ((planeback && d > -0.75f) || (!planeback && d < 0.75f))
	{
		return;  /* angle to surface too oblique */
	}

	/* Skip translucent / invisible surfaces — decals on glass or
	 * NODRAW surfaces look wrong. (KMQuake2 used SURF_ALPHATEST which
	 * is a KMQuake2 extension; stock Q2's nearest equivalents are
	 * SURF_TRANS33 | SURF_TRANS66 | SURF_NODRAW.) */
	if (surf->texinfo->flags & (SURF_TRANS33 | SURF_TRANS66 | SURF_NODRAW))
	{
		return;
	}

	for (i = 2; i < surf->numedges; i++)
	{
		mf = &cm_markFragments[cm_numMarkFragments];
		mf->firstPoint = mf->numPoints = 0;
		mf->node = node;

		VectorCopy(worldVert(0, surf), points[0]);
		VectorCopy(worldVert(i - 1, surf), points[1]);
		VectorCopy(worldVert(i, surf), points[2]);

		R_ClipFragment(3, points[0], 0, mf);

		if (mf->numPoints)
		{
			cm_numMarkFragments++;
			if (cm_numMarkPoints >= cm_maxMarkPoints ||
			    cm_numMarkFragments >= cm_maxMarkFragments)
			{
				return;
			}
		}
	}
}

static void
R_RecursiveMarkFragments(const vec3_t origin, const vec3_t normal,
		float radius, mnode_t *node)
{
	int        i;
	float      dist;
	cplane_t  *plane;
	msurface_t *surf;

	if (cm_numMarkPoints >= cm_maxMarkPoints ||
	    cm_numMarkFragments >= cm_maxMarkFragments)
	{
		return;
	}

	if (node->contents != -1)
	{
		return;  /* hit a leaf */
	}

	plane = node->plane;
	if (plane->type < 3)
	{
		dist = origin[plane->type] - plane->dist;
	}
	else
	{
		dist = DotProduct(origin, plane->normal) - plane->dist;
	}

	if (dist > radius)
	{
		R_RecursiveMarkFragments(origin, normal, radius, node->children[0]);
		return;
	}
	if (dist < -radius)
	{
		R_RecursiveMarkFragments(origin, normal, radius, node->children[1]);
		return;
	}

	surf = r_worldmodel->surfaces + node->firstsurface;
	for (i = 0; i < node->numsurfaces; i++, surf++)
	{
		if (surf->checkCount == r_decal_check)
		{
			continue;  /* already visited via another node */
		}

		if (surf->texinfo->flags & (SURF_SKY | SURF_WARP))
		{
			continue;
		}

		surf->checkCount = r_decal_check;
		R_ClipFragmentToSurface(surf, normal, node);
	}

	R_RecursiveMarkFragments(origin, normal, radius, node->children[0]);
	R_RecursiveMarkFragments(origin, normal, radius, node->children[1]);
}

int
R_MarkFragments(const vec3_t origin, const vec3_t axis[3], float radius,
		int maxPoints, vec3_t *points, int maxFragments,
		markFragment_t *fragments)
{
	int   i;
	float dot;

	if (!r_worldmodel || !r_worldmodel->nodes)
	{
		return 0;
	}

	r_decal_check++;

	cm_numMarkPoints = 0;
	cm_maxMarkPoints = maxPoints;
	cm_markPoints = points;

	cm_numMarkFragments = 0;
	cm_maxMarkFragments = maxFragments;
	cm_markFragments = fragments;

	for (i = 0; i < 3; i++)
	{
		dot = DotProduct(origin, axis[i]);

		VectorCopy(axis[i], cm_markPlanes[i * 2 + 0].normal);
		cm_markPlanes[i * 2 + 0].dist = dot - radius;
		cm_markPlanes[i * 2 + 0].type = PlaneTypeForNormal(cm_markPlanes[i * 2 + 0].normal);

		VectorNegate(axis[i], cm_markPlanes[i * 2 + 1].normal);
		cm_markPlanes[i * 2 + 1].dist = -dot - radius;
		cm_markPlanes[i * 2 + 1].type = PlaneTypeForNormal(cm_markPlanes[i * 2 + 1].normal);
	}

	R_RecursiveMarkFragments(origin, axis[0], radius, r_worldmodel->nodes);

	return cm_numMarkFragments;
}

/*
=================
Decal manager
=================
*/

void
R_ClearDecals(void)
{
	memset(r_decals, 0, sizeof(r_decals));
	r_decal_next = 0;
}

void
R_LoadDecalTextures(void)
{
	int i;
	static const int wrap_modes[3][2] = {
		{GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE},
		{GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE},
		{0, 0}
	};

	r_decal_textures[DECAL_BULLET]     = R_FindImage("decals/bullet.tga",     it_sprite);
	r_decal_textures[DECAL_BLOOD]      = R_FindImage("decals/blood.tga",      it_sprite);
	r_decal_textures[DECAL_SCORCH]     = R_FindImage("decals/scorch.tga",     it_sprite);
	r_decal_textures[DECAL_GREENBLOOD] = R_FindImage("decals/greenblood.tga", it_sprite);

	/* Clamp wrap so the alpha-zero edges of the texture stay alpha-zero
	 * even if texcoords drift slightly outside [0,1] due to numerical
	 * imprecision in the clipper. Default GL_REPEAT would wrap the
	 * opaque dark center of the texture into the visible boundary. */
	for (i = 0; i < 4; i++)
	{
		if (r_decal_textures[i])
		{
			R_Bind(r_decal_textures[i]->texnum);
			qglTexParameteri(GL_TEXTURE_2D, wrap_modes[0][0], wrap_modes[0][1]);
			qglTexParameteri(GL_TEXTURE_2D, wrap_modes[1][0], wrap_modes[1][1]);
		}
	}

	ri.Con_Printf(PRINT_ALL, "Decals: bullet=%s blood=%s scorch=%s greenblood=%s\n",
			r_decal_textures[DECAL_BULLET]     ? "OK" : "MISSING",
			r_decal_textures[DECAL_BLOOD]      ? "OK" : "MISSING",
			r_decal_textures[DECAL_SCORCH]     ? "OK" : "MISSING",
			r_decal_textures[DECAL_GREENBLOOD] ? "OK" : "MISSING");
}

void
R_RegisterDecalCvars(void)
{
	gl_decals     = ri.Cvar_Get("gl_decals",      "1",   CVAR_ARCHIVE);
	gl_decal_max  = ri.Cvar_Get("gl_decal_max",   "32",  CVAR_ARCHIVE);
	gl_decal_life = ri.Cvar_Get("gl_decal_life",  "20",  CVAR_ARCHIVE);
	gl_decal_fade = ri.Cvar_Get("gl_decal_fade",  "3",   CVAR_ARCHIVE);
}

/*
 * Build a basis (right, up, normal) around the surface normal so the
 * fragment clipper can carve a square decal patch out of the BSP
 * geometry. The `axis` form expected by R_MarkFragments is six clipping
 * planes — two per basis vector — so we need three orthogonal vectors.
 *
 * The choice of which world axis to project against is just "the one
 * least aligned with the surface normal" — produces stable basis for
 * walls, floors and ceilings alike.
 */
static void
MakeNormalVectors(const vec3_t normal, vec3_t right, vec3_t up)
{
	float d;
	vec3_t tmp;

	if (fabsf(normal[0]) < 0.9f)
	{
		tmp[0] = 1.0f; tmp[1] = 0.0f; tmp[2] = 0.0f;
	}
	else
	{
		tmp[0] = 0.0f; tmp[1] = 1.0f; tmp[2] = 0.0f;
	}

	d = DotProduct(tmp, normal);
	right[0] = tmp[0] - d * normal[0];
	right[1] = tmp[1] - d * normal[1];
	right[2] = tmp[2] - d * normal[2];
	VectorNormalize(right);

	CrossProduct(normal, right, up);
}

void
R_AddDecal(const vec3_t origin, const vec3_t normal,
		float radius, int type)
{
	int            maxDecals;
	int            i, slot;
	int            numFrags;
	int            verts_needed;
	vec3_t         axis[3];
	vec3_t         scratch_points[MAX_FRAGMENT_POINTS];
	markFragment_t scratch_frags[16];
	r_decal_t     *d;
	float          now;

	if (!gl_decals || !gl_decals->value)
	{
		return;
	}

	if (!r_worldmodel || type < 0 || type > 3)
	{
		return;
	}

	if (!r_decal_textures[type])
	{
		return;  /* texture missing; quietly skip */
	}

	maxDecals = (int)gl_decal_max->value;
	if (maxDecals > MAX_DECALS) maxDecals = MAX_DECALS;
	if (maxDecals < 1) maxDecals = 1;

	/* Build a clipping basis around the surface normal. */
	VectorCopy(normal, axis[0]);
	MakeNormalVectors(normal, axis[1], axis[2]);

	numFrags = R_MarkFragments(origin, (const vec3_t *)axis, radius,
			MAX_FRAGMENT_POINTS, scratch_points,
			16, scratch_frags);

	if (numFrags <= 0)
	{
		return;
	}

	/* Tally the verts before committing — if we'd overflow the pool,
	 * just drop the decal rather than partial-commit. */
	verts_needed = 0;
	for (i = 0; i < numFrags; i++)
	{
		verts_needed += scratch_frags[i].numPoints;
	}
	if (verts_needed > MAX_DECAL_VERTS / 4)
	{
		return;  /* one decal should never claim a quarter of the pool */
	}

	/* Pick a slot — FIFO replace. */
	slot = r_decal_next % maxDecals;
	r_decal_next = (r_decal_next + 1) % maxDecals;
	d = &r_decals[slot];

	/* Free old verts implicitly by overwriting; the vert pool is a
	 * round-robin too. Start placing verts immediately after the
	 * previous decal's last write or wrap to 0. */
	{
		static int decal_vert_head = 0;
		if (decal_vert_head + verts_needed > MAX_DECAL_VERTS)
		{
			decal_vert_head = 0;
		}
		d->firstPoint = decal_vert_head;
		d->numPoints  = verts_needed;
		d->numFragments = (numFrags > 16) ? 16 : numFrags;

		{
			int frag_i;
			int dst_off = 0;
			for (frag_i = 0; frag_i < d->numFragments; frag_i++)
			{
				int n = scratch_frags[frag_i].numPoints;
				int src_first = scratch_frags[frag_i].firstPoint;
				int j;
				d->fragOffsets[frag_i] = dst_off;
				d->fragLens[frag_i] = n;
				for (j = 0; j < n; j++)
				{
					VectorCopy(scratch_points[src_first + j],
							r_decal_verts[decal_vert_head + dst_off + j]);
				}
				dst_off += n;
			}
		}
		decal_vert_head += verts_needed;
	}

	/* Stash the texgen basis + radius so R_DrawDecals can compute
	 * accurate (s, t) — see r_decal_t comment. */
	VectorCopy(origin, d->origin);
	VectorCopy(axis[1], d->right);
	VectorCopy(axis[2], d->up);
	d->radius = radius;

	/* Per-decal random rotation breaks pattern repetition on walls.
	 * Sampling rand() once at spawn and stashing cos/sin avoids per-
	 * pixel transcendentals at draw time. Cheap and stays deterministic
	 * within a single decal's lifetime. */
	{
		float ang = (rand() & 0xfff) * (2.0f * (float)M_PI / 4096.0f);
		d->rotCos = cosf(ang);
		d->rotSin = sinf(ang);
	}

	now = (r_newrefdef.time != 0.0f) ? r_newrefdef.time : 0.0f;
	d->inUse = true;
	d->time = now;
	d->fadeStart = now + gl_decal_life->value;
	d->fadeEnd   = d->fadeStart + gl_decal_fade->value;
	d->texture = r_decal_textures[type];

	/* Stash origin in a deterministic place for the texgen pass. We
	 * reuse the last-but-one fragOffset slot since numFragments<=16. */
}

/*
 * R_DrawDecals — render all live decals.
 *
 * Called from R_RenderFrame after R_DrawAlphaSurfaces (so opaque world
 * is already in z-buffer) and before R_Flash. Decals are alpha-blended
 * quads coplanar with the BSP surface; glPolygonOffset biases them
 * toward the camera so they don't z-fight.
 *
 * Texgen: we project decal verts onto the impact-point basis to derive
 * (s, t). Cheap and works for arbitrarily-shaped fragments.
 */

static void
DecalTexCoord(const vec3_t v, const vec3_t origin,
		const vec3_t right, const vec3_t up, float radius,
		float rotCos, float rotSin, float *s, float *t)
{
	vec3_t diff;
	float  inv = 0.5f / radius;
	float  pr, pu;
	VectorSubtract(v, origin, diff);
	pr = DotProduct(diff, right) * inv;
	pu = DotProduct(diff, up)    * inv;
	/* Rotate in plane around the centroid (0.5, 0.5 in texcoord space). */
	*s = 0.5f + pr * rotCos - pu * rotSin;
	*t = 0.5f + pr * rotSin + pu * rotCos;
}

void
R_DrawDecals(void)
{
	int    i, frag_i, j;
	float  now, alpha;

	if (!gl_decals || !gl_decals->value)
	{
		return;
	}

	now = r_newrefdef.time;

	/* Drain any pending 3D batch — we own state for the decal pass. */
	R_ApplyGLBuffer();

	/* Force single-texture state. The world pass leaves multitex ON
	 * (TMU0 = base texture, TMU1 = lightmap with overbright combiner).
	 * If we don't disable TMU1 explicitly, the decal binds to TMU0 but
	 * still gets modulated by whatever TMU1 had last — visually that
	 * showed up on the GMA 950 as "light grey bullet holes" because
	 * the overbright lightmap was still in the pipeline. */
	R_EnableMultitexture(false);

	qglEnable(GL_BLEND);
	qglBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
	qglDepthMask(GL_FALSE);
	qglEnable(GL_POLYGON_OFFSET_FILL);
	qglPolygonOffset(-1.0f, -2.0f);
	qglDisable(GL_ALPHA_TEST);
	qglShadeModel(GL_FLAT);

	R_TexEnv(GL_MODULATE);

	for (i = 0; i < MAX_DECALS; i++)
	{
		r_decal_t *d = &r_decals[i];
		if (!d->inUse)
		{
			continue;
		}

		if (now > d->fadeEnd)
		{
			d->inUse = false;
			continue;
		}

		alpha = 1.0f;
		if (now > d->fadeStart && d->fadeEnd > d->fadeStart)
		{
			alpha = 1.0f - (now - d->fadeStart) / (d->fadeEnd - d->fadeStart);
		}

		qglColor4f(1.0f, 1.0f, 1.0f, alpha);
		R_Bind(d->texture->texnum);

		for (frag_i = 0; frag_i < d->numFragments; frag_i++)
		{
			int  fn = d->fragLens[frag_i];
			int  base = d->firstPoint + d->fragOffsets[frag_i];
			float s, t;

			qglBegin(GL_TRIANGLE_FAN);
			for (j = 0; j < fn; j++)
			{
				DecalTexCoord(r_decal_verts[base + j],
						d->origin, d->right, d->up,
						d->radius, d->rotCos, d->rotSin, &s, &t);
				qglTexCoord2f(s, t);
				qglVertex3fv(r_decal_verts[base + j]);
			}
			qglEnd();
		}
	}

	qglDisable(GL_POLYGON_OFFSET_FILL);
	qglPolygonOffset(0.0f, 0.0f);
	qglDepthMask(GL_TRUE);
	qglDisable(GL_BLEND);
	qglEnable(GL_ALPHA_TEST);
	qglColor4f(1.0f, 1.0f, 1.0f, 1.0f);
	R_TexEnv(GL_REPLACE);
}
