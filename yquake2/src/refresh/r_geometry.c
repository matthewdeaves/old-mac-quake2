/* Optional retained geometry paths for the fixed-function renderer.
 * GPL-2.0-or-later. All caches are owned by Mod_Free, never by an inline BSP.
 */
#include "header/local.h"
#include <stddef.h>
#include <stdlib.h>

#ifndef GL_ARRAY_BUFFER_ARB
#define GL_ARRAY_BUFFER_ARB 0x8892
#define GL_STATIC_DRAW_ARB 0x88E4
#endif

#define WORLD_INDEX_BATCH 16384
#define WORLD_CACHE_BYTES (8 * 1024 * 1024)

typedef struct { int first, count; } mesh_range_t;
typedef struct worldmesh_s
{
	float *vertices;
	GLuint *indices;
	mesh_range_t *ranges;
	int numvertices;
	GLuint vbo;
	qboolean tried_vbo;
	void (APIENTRY *bind)(GLenum, GLuint);
	void (APIENTRY *destroy)(GLsizei, const GLuint *);
} worldmesh_t;

static struct
{
	worldmesh_t *mesh;
	GLuint indices[WORLD_INDEX_BATCH];
	int count, texture, lightmap, firstvertex, lastvertex;
	qboolean mtex;
	float scroll;
} world_batch;

void
R_FreeWorldMesh(model_t *mod)
{
	worldmesh_t *m = mod->worldmesh;
	if (!m) return;
	if (world_batch.mesh == m) R_FlushWorldMesh();
	if (m->vbo) m->destroy(1, &m->vbo);
	free(m->vertices);
	free(m->indices);
	free(m->ranges);
	free(m);
	mod->worldmesh = NULL;
}

void
R_BuildWorldMesh(model_t *mod)
{
	worldmesh_t *m;
	int i, j, nv = 0, ni = 0;
	if (mod->worldmesh || mod->worldmesh_attempted || !gl_staticworld->value) return;
	mod->worldmesh_attempted = true;
	/* Only opaque, non-warp surfaces have immutable coordinates here.
	 * Flowing surfaces use a texture-matrix translation at draw time. */
	for (i = 0; i < mod->numsurfaces; i++)
	{
		msurface_t *s = &mod->surfaces[i];
		glpoly_t *p = s->polys;
		if (!p || p->numverts < 3 || p->chain ||
			(s->texinfo->flags & (SURF_SKY | SURF_WARP | SURF_TRANS33 | SURF_TRANS66))) continue;
		if (p->numverts > WORLD_INDEX_BATCH / 3) continue;
		nv += p->numverts;
		ni += (p->numverts - 2) * 3;
		if ((size_t)nv * VERTEXSIZE * sizeof(float) +
			(size_t)ni * sizeof(GLuint) > WORLD_CACHE_BYTES) return;
	}
	if (!nv) return;
	m = calloc(1, sizeof(*m));
	if (!m) return;
	m->vertices = malloc((size_t)nv * VERTEXSIZE * sizeof(float));
	m->indices = malloc((size_t)ni * sizeof(GLuint));
	m->ranges = calloc(mod->numsurfaces, sizeof(*m->ranges));
	mod->worldmesh = m;
	if (!m->vertices || !m->indices || !m->ranges)
	{
		R_FreeWorldMesh(mod);
		return;
	}
	nv = ni = 0;
	for (i = 0; i < mod->numsurfaces; i++)
	{
		msurface_t *s = &mod->surfaces[i];
		glpoly_t *p = s->polys;
		if (!p || p->numverts < 3 || p->chain ||
			(s->texinfo->flags & (SURF_SKY | SURF_WARP | SURF_TRANS33 | SURF_TRANS66))) continue;
		if (p->numverts > WORLD_INDEX_BATCH / 3) continue;
		m->ranges[i].first = ni;
		m->ranges[i].count = (p->numverts - 2) * 3;
		memcpy(m->vertices + nv * VERTEXSIZE, p->verts,
			(size_t)p->numverts * VERTEXSIZE * sizeof(float));
		for (j = 1; j < p->numverts - 1; j++)
		{
			m->indices[ni++] = nv;
			m->indices[ni++] = nv + j;
			m->indices[ni++] = nv + j + 1;
		}
		nv += p->numverts;
	}
	m->numvertices = nv;
}

static void
R_TryWorldVBO(worldmesh_t *m)
{
	void (APIENTRY *generate)(GLsizei, GLuint *);
	void (APIENTRY *upload)(GLenum, ptrdiff_t, const void *, GLenum);
	if (m->tried_vbo || gl_staticworld->value < 2) return;
	m->tried_vbo = true;
	/* No direct linkage to newer GL symbols in the Panther binary. */
	if (!strstr(gl_config.extensions_string, "GL_ARB_vertex_buffer_object")) return;
	m->bind = (void *)GetProcAddressGL("glBindBufferARB");
	m->destroy = (void *)GetProcAddressGL("glDeleteBuffersARB");
	generate = (void *)GetProcAddressGL("glGenBuffersARB");
	upload = (void *)GetProcAddressGL("glBufferDataARB");
	if (!m->bind || !m->destroy || !generate || !upload) return;
	generate(1, &m->vbo);
	if (!m->vbo) return;
	m->bind(GL_ARRAY_BUFFER_ARB, m->vbo);
	upload(GL_ARRAY_BUFFER_ARB,
		(ptrdiff_t)m->numvertices * VERTEXSIZE * sizeof(float), m->vertices, GL_STATIC_DRAW_ARB);
	if (qglGetError() != GL_NO_ERROR)
	{
		m->destroy(1, &m->vbo);
		m->vbo = 0;
	}
	m->bind(GL_ARRAY_BUFFER_ARB, 0);
}

void
R_FlushWorldMesh(void)
{
	worldmesh_t *m = world_batch.mesh;
	const byte *base;
	qboolean vbo, locked;
	if (!world_batch.count) return;
	R_TryWorldVBO(m);
	vbo = m->vbo && gl_staticworld->value >= 2;
	base = (const byte *)m->vertices;
	if (vbo) m->bind(GL_ARRAY_BUFFER_ARB, m->vbo);
	if (world_batch.mtex)
	{
		R_MBind(QGL_TEXTURE1, gl_state.lightmap_textures + world_batch.lightmap);
		R_MBind(QGL_TEXTURE0, world_batch.texture);
		qglClientActiveTextureARB(QGL_TEXTURE0);
	}
	else
	{
		R_SelectTexture(QGL_TEXTURE0);
		R_Bind(world_batch.texture);
		R_TexEnv(GL_REPLACE);
	}
	qglEnableClientState(GL_VERTEX_ARRAY);
	qglEnableClientState(GL_TEXTURE_COORD_ARRAY);
	qglVertexPointer(3, GL_FLOAT, VERTEXSIZE * sizeof(float), vbo ? (void *)0 : base);
	qglTexCoordPointer(2, GL_FLOAT, VERTEXSIZE * sizeof(float),
		vbo ? (void *)(3 * sizeof(float)) : base + 3 * sizeof(float));
	if (world_batch.scroll)
	{
		R_SelectTexture(QGL_TEXTURE0);
		qglMatrixMode(GL_TEXTURE);
		qglPushMatrix();
		qglTranslatef(world_batch.scroll, 0, 0);
		qglMatrixMode(GL_MODELVIEW);
	}
	if (world_batch.mtex)
	{
		qglClientActiveTextureARB(QGL_TEXTURE1);
		qglEnableClientState(GL_TEXTURE_COORD_ARRAY);
		qglTexCoordPointer(2, GL_FLOAT, VERTEXSIZE * sizeof(float),
			vbo ? (void *)(5 * sizeof(float)) : base + 5 * sizeof(float));
		qglClientActiveTextureARB(QGL_TEXTURE0);
	}
	/* Bound the hinted transform range. Material batching can span a large
	 * part of the map: locking that entire span would defeat the CPU saving.
	 * VBO storage has its own driver lifetime and needs no client-array lock. */
	locked = !vbo && gl_mesh_lockarrays->value && qglLockArraysEXT && qglUnlockArraysEXT &&
		world_batch.lastvertex - world_batch.firstvertex < WORLD_INDEX_BATCH;
	if (locked) qglLockArraysEXT(world_batch.firstvertex,
		world_batch.lastvertex - world_batch.firstvertex + 1);
	qglDrawElements(GL_TRIANGLES, world_batch.count, GL_UNSIGNED_INT, world_batch.indices);
	if (locked) qglUnlockArraysEXT();
	if (world_batch.mtex)
	{
		qglClientActiveTextureARB(QGL_TEXTURE1);
		qglDisableClientState(GL_TEXTURE_COORD_ARRAY);
		qglClientActiveTextureARB(QGL_TEXTURE0);
	}
	if (world_batch.scroll)
	{
		qglMatrixMode(GL_TEXTURE);
		qglPopMatrix();
		qglMatrixMode(GL_MODELVIEW);
	}
	qglDisableClientState(GL_TEXTURE_COORD_ARRAY);
	qglDisableClientState(GL_VERTEX_ARRAY);
	if (vbo) m->bind(GL_ARRAY_BUFFER_ARB, 0);
	world_batch.count = 0;
	world_batch.mesh = NULL;
}

qboolean
R_QueueWorldSurface(msurface_t *surf, int texture, int lightmap,
		qboolean multitexture, float scroll)
{
	worldmesh_t *m = currentmodel->worldmesh;
	mesh_range_t *range;
	if (!gl_staticworld->value || !m || currentmodel != r_worldmodel ||
		(multitexture && !qglClientActiveTextureARB)) return false;
	range = &m->ranges[surf - currentmodel->surfaces];
	if (!range->count) return false;
	if (world_batch.mesh != m || world_batch.texture != texture ||
		world_batch.lightmap != lightmap || world_batch.mtex != multitexture ||
		world_batch.scroll != scroll || world_batch.count + range->count > WORLD_INDEX_BATCH)
	{
		R_ApplyGLBuffer();
		world_batch.mesh = m;
		world_batch.texture = texture;
		world_batch.lightmap = lightmap;
		world_batch.mtex = multitexture;
		world_batch.scroll = scroll;
	}
	/* Each retained surface is a contiguous fan in the vertex store. */
	{
		int first = m->indices[range->first];
		int last = first + range->count / 3 + 1;
		if (!world_batch.count || first < world_batch.firstvertex) world_batch.firstvertex = first;
		if (!world_batch.count || last > world_batch.lastvertex) world_batch.lastvertex = last;
	}
	memcpy(world_batch.indices + world_batch.count, m->indices + range->first,
		(size_t)range->count * sizeof(GLuint));
	world_batch.count += range->count;
	return true;
}

typedef struct
{
	float xyz[3], st[2], normal[3], color[4];
	int source;
} aliasvertex_t;

typedef struct aliasmesh_s
{
	aliasvertex_t *vertices;
	GLushort *indices, *shadowindices;
	int numvertices, numindices;
} aliasmesh_t;

void
R_FreeAliasMesh(model_t *mod)
{
	aliasmesh_t *m = mod->aliasmesh;
	if (!m) return;
	free(m->vertices);
	free(m->indices);
	free(m->shadowindices);
	free(m);
	mod->aliasmesh = NULL;
}

void
R_BuildAliasMesh(model_t *mod)
{
	dmdl_t *h = mod->extradata;
	aliasmesh_t *m;
	int *order, *end, *lookup = NULL, count, n, i, j, fan;
	unsigned table_size = 1;
	GLushort first = 0, previous = 0, before = 0, index;
	if (mod->aliasmesh || mod->aliasmesh_attempted) return;
	mod->aliasmesh_attempted = true;
	if (!h || h->num_xyz <= 0 || h->num_xyz > MAX_VERTS ||
		h->num_glcmds <= 0 || h->num_glcmds > 65535) return;
	/* Validate the command extent before following it. Allocations have a
	 * hard cap and remain outside the fixed MD2 hunk. */
	if (h->ofs_glcmds < 0 || h->ofs_glcmds > mod->extradatasize ||
		h->num_glcmds > (mod->extradatasize - h->ofs_glcmds) / (int)sizeof(int)) return;
	m = calloc(1, sizeof(*m));
	if (!m) return;
	m->vertices = calloc(h->num_glcmds / 3 + 1, sizeof(*m->vertices));
	m->indices = malloc((size_t)h->num_glcmds * 3 * sizeof(GLushort));
	m->shadowindices = malloc((size_t)h->num_glcmds * 3 * sizeof(GLushort));
	while (table_size < (unsigned)h->num_glcmds) table_size *= 2;
	lookup = malloc(table_size * sizeof(*lookup));
	mod->aliasmesh = m;
	if (!m->vertices || !m->indices || !m->shadowindices || !lookup) goto invalid;
	memset(lookup, 0xff, table_size * sizeof(*lookup));
	order = (int *)((byte *)h + h->ofs_glcmds);
	end = order + h->num_glcmds;
	while (order < end)
	{
		count = *order++;
		if (!count)
		{
			for (i = 0; i < m->numindices; i++)
				m->shadowindices[i] = m->vertices[m->indices[i]].source;
			free(lookup);
			return;
		}
		/* Avoid abs(INT_MIN), short primitives and truncated streams. */
		if (count < -65535 || count > 65535) goto invalid;
		fan = count < 0;
		n = fan ? -count : count;
		if (n < 3 || n > (end - order) / 3) goto invalid;
		for (i = 0; i < n; i++, order += 3)
		{
			float st[2];
			unsigned bits[2], hash;
			memcpy(st, order, sizeof(st));
			memcpy(bits, order, sizeof(bits));
			if (order[2] < 0 || order[2] >= h->num_xyz) goto invalid;
			/* UV seams are distinct render vertices, sharing interpolated XYZ. */
			hash = bits[0] * 31u + bits[1] * 17u + (unsigned)order[2] * 2654435761u;
			hash = (hash ^ (hash >> 16)) & (table_size - 1);
			while (lookup[hash] >= 0)
			{
				j = lookup[hash];
				if (m->vertices[j].source == order[2] && !memcmp(m->vertices[j].st, st, sizeof(st))) break;
				hash = (hash + 1) & (table_size - 1);
			}
			j = lookup[hash];
			if (j < 0)
			{
				j = m->numvertices;
				lookup[hash] = j;
				m->vertices[j].source = order[2];
				memcpy(m->vertices[j].st, st, sizeof(st));
				m->numvertices++;
			}
			index = j;
			if (i == 0) first = index;
			if (i >= 2)
			{
				m->indices[m->numindices++] = fan ? first : ((i & 1) ? previous : before);
				m->indices[m->numindices++] = fan ? previous : ((i & 1) ? before : previous);
				m->indices[m->numindices++] = index;
			}
			before = previous;
			previous = index;
		}
	}
invalid:
	free(lookup);
	R_FreeAliasMesh(mod);
}

qboolean
R_DrawIndexedAlias(model_t *mod, float (*positions)[4], dtrivertx_t *verts,
		float *shadedots, float *light, float alpha, qboolean shell, qboolean glow)
{
	aliasmesh_t *m;
	int i, j;
	qboolean locked;
	static float colors[MAX_VERTS][4];
	dmdl_t *h = mod->extradata;
	extern float r_avertexnormals[162][3];
	if (!gl_indexedmodels->value) return false;
	if (!mod->aliasmesh) R_BuildAliasMesh(mod);
	m = mod->aliasmesh;
	if (!m || !m->numindices) return false;
	for (i = 0; i < h->num_xyz; i++)
	{
		float l = shell ? 1.0f : shadedots[verts[i].lightnormalindex];
		for (j = 0; j < 3; j++) colors[i][j] = l * light[j];
		colors[i][3] = alpha;
	}
	for (i = 0; i < m->numvertices; i++)
	{
		aliasvertex_t *v = &m->vertices[i];
		int normal = verts[v->source].lightnormalindex;
		memcpy(v->xyz, positions[v->source], sizeof(v->xyz));
		memcpy(v->color, colors[v->source], sizeof(v->color));
		if (glow) memcpy(v->normal, r_avertexnormals[normal < 162 ? normal : 0], sizeof(v->normal));
	}
	qglEnableClientState(GL_VERTEX_ARRAY);
	qglEnableClientState(GL_COLOR_ARRAY);
	qglVertexPointer(3, GL_FLOAT, sizeof(aliasvertex_t), m->vertices[0].xyz);
	qglColorPointer(4, GL_FLOAT, sizeof(aliasvertex_t), m->vertices[0].color);
	if (!shell)
	{
		qglEnableClientState(GL_TEXTURE_COORD_ARRAY);
		qglTexCoordPointer(2, GL_FLOAT, sizeof(aliasvertex_t), m->vertices[0].st);
	}
	if (glow)
	{
		qglEnableClientState(GL_NORMAL_ARRAY);
		qglNormalPointer(GL_FLOAT, sizeof(aliasvertex_t), m->vertices[0].normal);
	}
	locked = gl_mesh_lockarrays->value && qglLockArraysEXT && qglUnlockArraysEXT;
	if (locked) qglLockArraysEXT(0, m->numvertices);
	qglDrawElements(GL_TRIANGLES, m->numindices, GL_UNSIGNED_SHORT, m->indices);
	if (locked) qglUnlockArraysEXT();
	if (glow) qglDisableClientState(GL_NORMAL_ARRAY);
	if (!shell) qglDisableClientState(GL_TEXTURE_COORD_ARRAY);
	qglDisableClientState(GL_COLOR_ARRAY);
	qglDisableClientState(GL_VERTEX_ARRAY);
	return true;
}

qboolean
R_DrawIndexedShadow(model_t *mod, float (*positions)[4], float *shade,
		float lheight, float height)
{
	aliasmesh_t *m = mod->aliasmesh;
	static vec3_t projected[MAX_VERTS];
	dmdl_t *h = mod->extradata;
	int i;
	qboolean locked;
	if (!gl_indexedmodels->value || !m || !m->numindices) return false;
	for (i = 0; i < h->num_xyz; i++)
	{
		projected[i][0] = positions[i][0] - shade[0] * (positions[i][2] + lheight);
		projected[i][1] = positions[i][1] - shade[1] * (positions[i][2] + lheight);
		projected[i][2] = height;
	}
	qglEnableClientState(GL_VERTEX_ARRAY);
	qglVertexPointer(3, GL_FLOAT, 0, projected);
	locked = gl_mesh_lockarrays->value && qglLockArraysEXT && qglUnlockArraysEXT;
	if (locked) qglLockArraysEXT(0, h->num_xyz);
	qglDrawElements(GL_TRIANGLES, m->numindices, GL_UNSIGNED_SHORT, m->shadowindices);
	if (locked) qglUnlockArraysEXT();
	qglDisableClientState(GL_VERTEX_ARRAY);
	return true;
}
