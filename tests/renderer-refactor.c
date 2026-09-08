/* Exercise production renderer code with a recording GL implementation.
 * This is CPU/state validation, not a substitute for fleet frame comparisons.
 */
#include <assert.h>
#include <stdarg.h>
#include <stdint.h>
#include "../yquake2/src/refresh/r_geometry.c"
#include "../yquake2/src/refresh/r_light.c"
#include "../yquake2/src/refresh/r_surf.c"

refimport_t ri;
int QGL_TEXTURE0 = GL_TEXTURE0_ARB, QGL_TEXTURE1 = GL_TEXTURE1_ARB;
glconfig_t gl_config;
glstate_t gl_state;
model_t *currentmodel, *r_worldmodel;
entity_t *currententity;
refdef_t r_newrefdef;
int r_framecount;
float r_avertexnormals[162][3];
static cvar_t options[8];
cvar_t *gl_worldsort = &options[6];
cvar_t *gl_mesh_lockarrays = &options[7];
cvar_t *gl_staticworld = &options[0], *gl_indexedmodels = &options[1];
cvar_t *gl_lightmap_cache = &options[2], *gl_dynamic = &options[3];
cvar_t *gl_modulate = &options[4], *gl_minlight = &options[5];

static int client_unit, server_unit, enabled[2], drawcalls, uploads, rowlength;
static const byte *position_pointer, *color_pointer;
static int position_stride, color_stride;
static GLuint bound_vbo;
static byte vbo_data[4096];
static float drawn[1024][3], drawn_alpha;
static int drawn_count;
static GLenum next_error;
static int lock_first, lock_count, array_locked, array_locks;
static byte textures[DYNAMIC_PAGES][BLOCK_WIDTH * BLOCK_HEIGHT * 4];

void R_ApplyGLBuffer(void) { R_FlushWorldMesh(); }
void R_SelectTexture(GLenum unit) { server_unit = unit == QGL_TEXTURE1; }
void R_Bind(int texture) { gl_state.currenttextures[server_unit] = texture; }
void R_MBind(GLenum unit, int texture) { R_SelectTexture(unit); R_Bind(texture); }
void R_TexEnv(GLenum mode) { assert(mode == GL_REPLACE); }

static void APIENTRY bind_buffer(GLenum target, GLuint id) { (void)target; bound_vbo = id; }
static void APIENTRY delete_buffers(GLsizei n, const GLuint *ids) { (void)n; (void)ids; }
static void APIENTRY generate_buffers(GLsizei n, GLuint *ids) { assert(n == 1); *ids = 1; }
static void APIENTRY upload_buffer(GLenum target, ptrdiff_t size, const void *data, GLenum usage)
{
	(void)target; (void)usage;
	assert(size <= sizeof(vbo_data));
	memcpy(vbo_data, data, size);
}
void *GetProcAddressGL(char *name)
{
	if (!strcmp(name, "glBindBufferARB")) return (void *)bind_buffer;
	if (!strcmp(name, "glDeleteBuffersARB")) return (void *)delete_buffers;
	if (!strcmp(name, "glGenBuffersARB")) return (void *)generate_buffers;
	if (!strcmp(name, "glBufferDataARB")) return (void *)upload_buffer;
	return NULL;
}

static void APIENTRY enable_array(GLenum what) { enabled[client_unit] |= 1 << (what - GL_VERTEX_ARRAY); }
static void APIENTRY disable_array(GLenum what) { enabled[client_unit] &= ~(1 << (what - GL_VERTEX_ARRAY)); }
static void APIENTRY client_texture(GLenum unit) { client_unit = unit == QGL_TEXTURE1; }
static void APIENTRY vertex_pointer(GLint n, GLenum type, GLsizei stride, const void *pointer)
{
	assert(n == 3 && type == GL_FLOAT);
	position_pointer = bound_vbo ? vbo_data + (size_t)pointer : pointer;
	position_stride = stride ? stride : 3 * sizeof(float);
}
static void APIENTRY color_pointer_fn(GLint n, GLenum type, GLsizei stride, const void *pointer)
{
	assert(n == 4 && type == GL_FLOAT);
	color_pointer = pointer;
	color_stride = stride;
}
static void APIENTRY tex_pointer(GLint n, GLenum type, GLsizei stride, const void *pointer)
{ (void)n; (void)type; (void)stride; (void)pointer; }
static void APIENTRY normal_pointer(GLenum type, GLsizei stride, const void *pointer)
{ (void)type; (void)stride; (void)pointer; }
static void APIENTRY draw_elements(GLenum mode, GLsizei count, GLenum type, const void *indices)
{
	int i;
	assert(mode == GL_TRIANGLES && count % 3 == 0);
	assert(enabled[0] & 1);
	drawcalls++;
	for (i = 0; i < count; i++)
	{
		unsigned index = type == GL_UNSIGNED_INT ? ((const GLuint *)indices)[i] : ((const GLushort *)indices)[i];
		if (array_locked) assert(index >= lock_first && index < lock_first + lock_count);
		assert(drawn_count < 1024);
		memcpy(drawn[drawn_count++], position_pointer + index * position_stride, 3 * sizeof(float));
		if (enabled[0] & (1 << (GL_COLOR_ARRAY - GL_VERTEX_ARRAY)))
			drawn_alpha = ((const float *)(color_pointer + index * color_stride))[3];
	}
}
static GLenum APIENTRY get_error(void) { GLenum error = next_error; next_error = GL_NO_ERROR; return error; }
static void APIENTRY pixel_store(GLenum what, GLint value) { assert(what == GL_UNPACK_ROW_LENGTH); rowlength = value; }
static void APIENTRY tex_subimage(GLenum target, GLint level, GLint x, GLint y, GLsizei w, GLsizei h,
		GLenum format, GLenum type, const void *data)
{
	int row, page = gl_state.currenttextures[server_unit] - TEXNUM_DYNAMIC_FIRST;
	(void)target; (void)level; (void)format; (void)type;
	assert(page >= 0 && page < DYNAMIC_PAGES);
	assert(x >= 0 && y >= 0 && x + w <= BLOCK_WIDTH && y + h <= BLOCK_HEIGHT);
	for (row = 0; row < h; row++)
		memcpy(textures[page] + ((y + row) * BLOCK_WIDTH + x) * 4,
			(const byte *)data + row * (rowlength ? rowlength : w) * 4, w * 4);
	uploads++;
}
static void APIENTRY tex_image(GLenum target, GLint level, GLint internal, GLsizei w, GLsizei h,
		GLint border, GLenum format, GLenum type, const void *data)
{ (void)internal; (void)border; tex_subimage(target, level, 0, 0, w, h, format, type, data); }
static void APIENTRY noop_enum(GLenum value) { (void)value; }
static void APIENTRY noop_void(void) {}
static void APIENTRY noop_translate(GLfloat x, GLfloat y, GLfloat z) { (void)x; (void)y; (void)z; }
static void APIENTRY noop_parameter(GLenum target, GLenum name, GLint value) { (void)target; (void)name; (void)value; }
static void APIENTRY noop_delete(GLsizei count, const GLuint *textures_) { (void)count; (void)textures_; }
static void APIENTRY noop_mtex(GLenum unit, GLfloat s, GLfloat t) { (void)unit; (void)s; (void)t; }
static void APIENTRY lock_arrays(GLint first, GLsizei count)
{
	assert(!array_locked && !bound_vbo && count > 0);
	lock_first = first; lock_count = count; array_locked = 1; array_locks++;
}
static void APIENTRY unlock_arrays(void) { assert(array_locked); array_locked = 0; }
__typeof__(qglLockArraysEXT) qglLockArraysEXT = lock_arrays;
__typeof__(qglUnlockArraysEXT) qglUnlockArraysEXT = unlock_arrays;

__typeof__(qglEnableClientState) qglEnableClientState = enable_array;
__typeof__(qglDisableClientState) qglDisableClientState = disable_array;
__typeof__(qglClientActiveTextureARB) qglClientActiveTextureARB = client_texture;
__typeof__(qglVertexPointer) qglVertexPointer = vertex_pointer;
__typeof__(qglColorPointer) qglColorPointer = color_pointer_fn;
__typeof__(qglTexCoordPointer) qglTexCoordPointer = tex_pointer;
__typeof__(qglNormalPointer) qglNormalPointer = normal_pointer;
__typeof__(qglDrawElements) qglDrawElements = draw_elements;
__typeof__(qglGetError) qglGetError = get_error;
__typeof__(qglMatrixMode) qglMatrixMode = noop_enum;
__typeof__(qglPushMatrix) qglPushMatrix = noop_void;
__typeof__(qglPopMatrix) qglPopMatrix = noop_void;
__typeof__(qglTranslatef) qglTranslatef = noop_translate;
__typeof__(qglTexParameteri) qglTexParameteri = noop_parameter;
__typeof__(qglDeleteTextures) qglDeleteTextures = noop_delete;
__typeof__(qglPixelStorei) qglPixelStorei = pixel_store;
__typeof__(qglTexImage2D) qglTexImage2D = tex_image;
__typeof__(qglTexSubImage2D) qglTexSubImage2D = tex_subimage;
__typeof__(qglMTexCoord2fSGIS) qglMTexCoord2fSGIS = noop_mtex;

static void error_fn(int level, char *format, ...)
{ (void)level; (void)format; abort(); }

static void command_vertex(int *p, float s, float t, int xyz)
{ memcpy(p, &s, 4); memcpy(p + 1, &t, 4); p[2] = xyz; }

static void test_alias(void)
{
	model_t mod = {0};
	byte storage[sizeof(dmdl_t) + 32 * sizeof(int)] = {0};
	dmdl_t *h = (dmdl_t *)storage;
	int *commands = (int *)(storage + sizeof(*h));
	float positions[MAX_VERTS][4] = {{0}}, dots[256], light[3] = {0.5f, 0.75f, 1};
	dtrivertx_t verts[MAX_VERTS] = {{0}};
	GLushort expected[] = {0,1,2, 2,1,3, 4,1,2};
	int i;
	h->num_xyz = 4; h->ofs_glcmds = sizeof(*h); h->num_glcmds = 24;
	mod.extradata = h; mod.extradatasize = sizeof(storage);
	commands[0] = 4;
	for (i = 0; i < 4; i++) command_vertex(commands + 1 + i * 3, 0, 0, i);
	commands[13] = -3;
	command_vertex(commands + 14, 1, 0, 0); /* same XYZ, different UV */
	command_vertex(commands + 17, 0, 0, 1);
	command_vertex(commands + 20, 0, 0, 2);
	R_BuildAliasMesh(&mod);
	assert(mod.aliasmesh && mod.aliasmesh->numvertices == 5);
	assert(mod.aliasmesh->numindices == 9);
	assert(!memcmp(mod.aliasmesh->indices, expected, sizeof(expected)));
	assert(mod.aliasmesh->shadowindices[6] == 0);
	for (i = 0; i < 4; i++) { positions[i][0] = i; positions[i][2] = i * 2; }
	for (i = 0; i < 256; i++) dots[i] = 0.5f;
	gl_indexedmodels->value = 1;
	gl_mesh_lockarrays->value = 1;
	array_locks = 0;
	drawn_count = drawcalls = 0;
	assert(R_DrawIndexedAlias(&mod, positions, verts, dots, light, 0.25f, false, false));
	assert(drawcalls == 1 && drawn_count == 9 && drawn_alpha == 0.25f);
	assert(drawn[3][0] == 2 && drawn[6][0] == 0);
	assert(!enabled[0] && !enabled[1]);
	assert(array_locks == 1 && !array_locked);
	drawn_count = 0;
	assert(R_DrawIndexedShadow(&mod, positions, light, 2, 5));
	assert(drawn[3][0] == 2 - 0.5f * 6 && drawn[3][2] == 5);
	assert(array_locks == 2 && !array_locked);
	/* The switch and extension availability both gate locking. */
	gl_mesh_lockarrays->value = 0;
	drawn_count = 0;
	assert(R_DrawIndexedAlias(&mod, positions, verts, dots, light, 0.25f, false, false));
	assert(array_locks == 2 && !array_locked);
	gl_mesh_lockarrays->value = 1;
	qglUnlockArraysEXT = NULL;
	drawn_count = 0;
	assert(R_DrawIndexedAlias(&mod, positions, verts, dots, light, 0.25f, false, false));
	assert(array_locks == 2 && !array_locked);
	qglUnlockArraysEXT = unlock_arrays;
	R_FreeAliasMesh(&mod);
	mod.aliasmesh_attempted = false;
	commands[0] = INT32_MIN;
	R_BuildAliasMesh(&mod); assert(!mod.aliasmesh);
	mod.aliasmesh_attempted = false;
	commands[0] = 4; commands[3] = 4;
	R_BuildAliasMesh(&mod); assert(!mod.aliasmesh);
	mod.aliasmesh_attempted = false;
	commands[3] = 0; h->num_glcmds = 12;
	R_BuildAliasMesh(&mod); assert(!mod.aliasmesh);
	puts("alias: winding, UV seams, alpha, shadow reuse and malformed streams pass");
}

static void test_world(void)
{
	model_t mod = {0};
	msurface_t surfaces[2] = {{0}};
	mtexinfo_t tex = {0};
	glpoly_t polygons[2] = {{0}};
	int i, j, mode;
	mod.surfaces = surfaces; mod.numsurfaces = 2;
	for (i = 0; i < 2; i++)
	{
		surfaces[i].texinfo = &tex; surfaces[i].polys = &polygons[i];
		polygons[i].numverts = 4;
		for (j = 0; j < 4; j++) polygons[i].verts[j][0] = i * 4 + j;
	}
	currentmodel = r_worldmodel = &mod;
	gl_config.extensions_string = "GL_ARB_vertex_buffer_object";
	for (mode = 1; mode <= 2; mode++)
	{
		array_locks = 0;
		gl_staticworld->value = mode;
		R_BuildWorldMesh(&mod);
		drawn_count = drawcalls = 0;
		assert(R_QueueWorldSurface(surfaces, 4, 1, true, 0));
		assert(R_QueueWorldSurface(surfaces + 1, 4, 1, true, 0));
		assert(drawcalls == 0);
		R_FlushWorldMesh();
		assert(drawcalls == 1 && drawn_count == 12);
		assert(drawn[0][0] == 0 && drawn[3][0] == 0 && drawn[5][0] == 3 && drawn[6][0] == 4);
		assert(!enabled[0] && !enabled[1] && !bound_vbo && !client_unit);
		assert(!array_locked && array_locks == (mode == 1 ? 1 : 0));
	}
	drawn_count = drawcalls = 0;
	R_QueueWorldSurface(surfaces, 4, 0, false, 0);
	R_QueueWorldSurface(surfaces + 1, 5, 0, false, -64);
	assert(drawcalls == 1);
	R_FlushWorldMesh(); assert(drawcalls == 2);
	gl_staticworld->value = 0;
	assert(!R_QueueWorldSurface(surfaces, 4, 0, false, 0));
	R_FreeWorldMesh(&mod);
	assert(!mod.worldmesh);
	mod.worldmesh_attempted = false;
	gl_staticworld->value = 2;
	gl_config.extensions_string = "";
	R_BuildWorldMesh(&mod);
	drawn_count = drawcalls = 0;
	R_QueueWorldSurface(surfaces, 4, 0, false, 0); R_FlushWorldMesh();
	assert(drawcalls == 1 && !mod.worldmesh->vbo);
	R_FreeWorldMesh(&mod);
	mod.worldmesh_attempted = false;
	gl_config.extensions_string = "GL_ARB_vertex_buffer_object";
	R_BuildWorldMesh(&mod);
	next_error = GL_OUT_OF_MEMORY;
	drawn_count = drawcalls = 0;
	R_QueueWorldSurface(surfaces, 4, 0, false, 0); R_FlushWorldMesh();
	assert(drawcalls == 1 && !mod.worldmesh->vbo && !bound_vbo);
	R_FreeWorldMesh(&mod);
	currentmodel = r_worldmodel = NULL;
	/* A sparse batch must not lock all intervening map vertices. */
	{
		worldmesh_t sparse = {0};
		GLuint sparse_indices[] = {0, 1, WORLD_INDEX_BATCH};
		sparse.vertices = calloc((WORLD_INDEX_BATCH + 1) * VERTEXSIZE, sizeof(float));
		assert(sparse.vertices);
		gl_staticworld->value = 1;
		world_batch.mesh = &sparse;
		world_batch.count = 3;
		world_batch.firstvertex = 0;
		world_batch.lastvertex = WORLD_INDEX_BATCH;
		world_batch.mtex = false;
		world_batch.scroll = 0;
		memcpy(world_batch.indices, sparse_indices, sizeof(sparse_indices));
		array_locks = drawn_count = 0;
		R_FlushWorldMesh();
		assert(!array_locks && !array_locked && drawn_count == 3);
		free(sparse.vertices);
	}
	puts("world: retained indices, batching, client/VBO parity and state cleanup pass");
}

static unsigned random_state = 123;
static unsigned next_random(void) { random_state = random_state * 1664525u + 1013904223u; return random_state; }

static void test_lighting(void)
{
	msurface_t surface = {0}; mtexinfo_t tex = {0}; cplane_t plane = {{0,0,1},0};
	lightstyle_t styles[MAX_LIGHTSTYLES] = {{{0}}};
	dlight_t lights[4] = {{{0}}};
	byte samples[34 * 34 * 3 * MAXLIGHTMAPS], reference[34 * 34 * 4], actual[34 * 34 * 4];
	int trial, i, maps;
	surface.texinfo = &tex; surface.plane = &plane; surface.samples = samples;
	tex.vecs[0][0] = tex.vecs[1][1] = 1;
	r_framecount = surface.dlightframe = 10; surface.dlightbits = 15;
	r_newrefdef.lightstyles = styles; r_newrefdef.dlights = lights; r_newrefdef.num_dlights = 4;
	for (trial = 0; trial < 1000; trial++)
	{
		int w = 1 + next_random() % 34, h = 1 + next_random() % 34;
		surface.extents[0] = (w - 1) * 16; surface.extents[1] = (h - 1) * 16;
		maps = 1 + next_random() % MAXLIGHTMAPS;
		memset(surface.styles, 255, sizeof(surface.styles));
		for (i = 0; i < maps; i++)
		{
			surface.styles[i] = i;
			styles[i].rgb[0] = (next_random() % 500) * 0.01f;
			styles[i].rgb[1] = (next_random() % 500) * 0.01f;
			styles[i].rgb[2] = (next_random() % 500) * 0.01f;
		}
		for (i = 0; i < sizeof(samples); i++) samples[i] = next_random() >> 24;
		for (i = 0; i < 4; i++)
		{
			lights[i].origin[0] = (int)(next_random() % 16000) * 0.1f - 500;
			lights[i].origin[1] = (int)(next_random() % 16000) * 0.1f - 500;
			lights[i].origin[2] = (next_random() % 1000) * 0.1f;
			lights[i].intensity = 64 + next_random() % 500;
			lights[i].color[0] = (next_random() % 200) * 0.01f - 1;
			lights[i].color[1] = 0.5f; lights[i].color[2] = 1;
		}
		gl_modulate->value = 0.5f + (next_random() % 300) * 0.01f;
		gl_minlight->value = next_random() % 256;
		R_ClearLightCache(); /* samples are immutable in the engine, randomized here */
		gl_lightmap_cache->value = 0; R_BuildLightMap(&surface, reference, w * 4);
		gl_lightmap_cache->value = 1; R_BuildLightMap(&surface, actual, w * 4);
		assert(!memcmp(reference, actual, w * h * 4));
		memset(actual, 0, sizeof(actual));
		R_BuildLightMap(&surface, actual, w * 4); /* cache hit */
		assert(!memcmp(reference, actual, w * h * 4));
		styles[0].rgb[0] += 0.125f; /* style invalidation */
		gl_lightmap_cache->value = 0; R_BuildLightMap(&surface, reference, w * 4);
		gl_lightmap_cache->value = 1; R_BuildLightMap(&surface, actual, w * 4);
		assert(!memcmp(reference, actual, w * h * 4));
		/* Reuse static light with moving/expired dynamic lights and changed
		 * modulation/minlight. The cache must never retain a projectile. */
		lights[0].origin[0] += 71.25f;
		gl_modulate->value += 0.25f;
		gl_minlight->value = 255 - gl_minlight->value;
		gl_lightmap_cache->value = 0; R_BuildLightMap(&surface, reference, w * 4);
		gl_lightmap_cache->value = 1; R_BuildLightMap(&surface, actual, w * 4);
		assert(!memcmp(reference, actual, w * h * 4));
		surface.dlightframe = 0;
		gl_lightmap_cache->value = 0; R_BuildLightMap(&surface, reference, w * 4);
		gl_lightmap_cache->value = 1; R_BuildLightMap(&surface, actual, w * 4);
		assert(!memcmp(reference, actual, w * h * 4));
		surface.dlightframe = r_framecount;
	}
	{
		msurface_t many[256];
		for (i = 0; i < 256; i++)
		{
			many[i] = surface;
			many[i].extents[0] = many[i].extents[1] = 33 * 16;
			gl_lightmap_cache->value = 0; R_BuildLightMap(many + i, reference, 34 * 4);
			gl_lightmap_cache->value = 1; R_BuildLightMap(many + i, actual, 34 * 4);
			assert(!memcmp(reference, actual, sizeof(actual)));
			assert(lightcache_bytes <= LIGHTCACHE_BYTES);
		}
	}
	R_ClearLightCache();
	puts("lighting: randomized scalar/cache byte parity, bounded columns and style invalidation pass");
}

static void test_atlas(void)
{
	msurface_t surfaces[DYNAMIC_PAGES + 2] = {{0}};
	mtexinfo_t tex = {0}; cplane_t plane = {{0,0,1},0};
	lightstyle_t styles[MAX_LIGHTSTYLES] = {{{0}}};
	byte samples[12] = {10,20,30,40,50,60,70,80,90,100,110,120}, reference[16];
	int i, page;
	r_newrefdef.lightstyles = styles; r_newrefdef.num_dlights = 0;
	styles[0].rgb[0] = styles[0].rgb[1] = styles[0].rgb[2] = 1;
	gl_modulate->value = 1; gl_minlight->value = 0;
	gl_lightmap_cache->value = gl_dynamic->value = 1;
	gl_state.lightmap_textures = TEXNUM_LIGHTMAPS;
	gl_lms.internal_format = GL_RGBA;
	worlddraw_count = DYNAMIC_PAGES + 2;
	worlddraws = calloc(worlddraw_count, sizeof(*worlddraws));
	for (i = 0; i < worlddraw_count; i++)
	{
		msurface_t *s = surfaces + i;
		s->texinfo = &tex; s->plane = &plane; s->samples = samples;
		s->extents[0] = s->extents[1] = 16;
		s->light_s = i * 3; s->light_t = 2;
		s->lightmaptexturenum = i ? i : 1; /* first two share an atlas */
		s->dlightframe = r_framecount;
		memset(s->styles, 255, sizeof(s->styles)); s->styles[0] = 0;
		worlddraws[i].surface = s;
	}
	uploads = 0;
	R_PrepareWorldLights();
	assert(uploads == DYNAMIC_PAGES && !rowlength);
	assert(surfaces[DYNAMIC_PAGES + 1].prepared_lightframe == 0); /* bounded fallback */
	for (i = 0; i <= DYNAMIC_PAGES; i++)
	{
		msurface_t *s = surfaces + i;
		assert(s->prepared_lightframe == r_framecount);
		page = s->prepared_lightmap + TEXNUM_LIGHTMAPS - TEXNUM_DYNAMIC_FIRST;
		R_BuildLightMap(s, reference, 8);
		assert(!memcmp(reference, textures[page] + (2 * BLOCK_WIDTH + s->light_s) * 4, 8));
		assert(!memcmp(reference + 8, textures[page] + (3 * BLOCK_WIDTH + s->light_s) * 4, 8));
	}
	uploads = 0;
	R_PrepareWorldLights(); assert(uploads == DYNAMIC_PAGES && !rowlength);
	next_error = GL_OUT_OF_MEMORY;
	R_PrepareWorldLights(); assert(surfaces[0].prepared_lightframe == 0);
	R_FreeSurfaceQueue(); R_ClearLightCache();
	puts("atlas: non-overlapping slots, grouped uploads, bounded overflow and GL-error fallback pass");
}

int main(void)
{
	ri.Sys_Error = error_fn;
	test_alias(); test_world(); test_lighting(); test_atlas();
	return 0;
}
