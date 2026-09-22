/* Record production restore quads without creating a GL context. */
#include <assert.h>
#include "../yquake2/src/refresh/r_bloom.c"

viddef_t vid;
refdef_t r_newrefdef;
static float vertices[4][4], texcoord[2];
static int count;
static void APIENTRY begin(GLenum mode) { assert(mode == GL_QUADS); count = 0; }
static void APIENTRY end(void) { assert(count == 4); }
static void APIENTRY tex(GLfloat s, GLfloat t) { texcoord[0] = s; texcoord[1] = t; }
static void APIENTRY vertex(GLfloat x, GLfloat y)
{
	assert(count < 4);
	vertices[count][0] = x; vertices[count][1] = y;
	vertices[count][2] = texcoord[0]; vertices[count][3] = texcoord[1];
	count++;
}
__typeof__(qglBegin) qglBegin = begin;
__typeof__(qglEnd) qglEnd = end;
__typeof__(qglTexCoord2f) qglTexCoord2f = tex;
__typeof__(qglVertex2f) qglVertex2f = vertex;

/* Top-left vertex first, then bottom-left, bottom-right, top-right. */
static void
assert_quad(float x0, float y0, float x1, float y1,
		float s0, float t0, float s1, float t1)
{
	assert(vertices[0][0] == x0 && vertices[0][1] == y0);
	assert(vertices[0][2] == s0 && vertices[0][3] == t1);
	assert(vertices[1][0] == x0 && vertices[1][1] == y1);
	assert(vertices[1][2] == s0 && vertices[1][3] == t0);
	assert(vertices[2][0] == x1 && vertices[2][1] == y1);
	assert(vertices[2][2] == s1 && vertices[2][3] == t0);
	assert(vertices[3][0] == x1 && vertices[3][1] == y0);
	assert(vertices[3][2] == s1 && vertices[3][3] == t1);
}

int main(void)
{
	cvar_t fast = {0};
	float whole[4][4];
	float tw, th;
	int view, size;
	gl_bloom_fastrestore = &fast;
	vid.width = 1920; vid.height = 1080;
	screen_tex_w = screen_tex_h = 2048;
	tw = (float)vid.width / screen_tex_w;
	th = (float)vid.height / screen_tex_h;
	/* 0 full view; 1-4 offset/reduced; 5 a centred viewsize-80-style view
	 * whose rectangle does not reach the bottom-left workspace (#80). */
	for (view = 0; view < 6; view++)
	{
		r_newrefdef.x = view == 1 ? 32 : view == 5 ? 192 : 0;
		r_newrefdef.y = view == 2 ? 32 : view == 5 ? 108 : 0;
		r_newrefdef.width = view == 3 ? 1600 : view == 5 ? 1536 : vid.width;
		r_newrefdef.height = view == 4 ? 900 : view == 5 ? 864 : vid.height;
		R_Bloom_SetView();

		/* The capture spans the whole window; the downsample samples only
		 * the view's sub-rectangle of it (t measured from the bottom). */
		assert(scr_tcw == tw && scr_tch == th);
		assert(view_s0 == (float)r_newrefdef.x / screen_tex_w);
		assert(view_s1 == (float)(r_newrefdef.x + r_newrefdef.width) / screen_tex_w);
		assert(view_t0 == (float)(vid.height - r_newrefdef.y - r_newrefdef.height) / screen_tex_h);
		assert(view_t1 == (float)(vid.height - r_newrefdef.y) / screen_tex_h);
		R_Bloom_QuadST(0, 0, 256, 256, view_s0, view_t0, view_s1, view_t1);
		assert_quad(0, 0, 256, 256, view_s0, view_t0, view_s1, view_t1);

		for (size = 64; size <= 512; size *= 2)
		{
			BLOOM_SIZE = size;

			/* Full restore redraws the whole window, border included. */
			fast.value = 0;
			R_Bloom_RestoreScene();
			assert_quad(0, 0, vid.width, vid.height, 0, 0, tw, th);
			memcpy(whole, vertices, sizeof(whole));

			/* Fast restore redraws just the workspace corner, 1:1, for
			 * every view: the capture covers the border too. */
			fast.value = 1;
			R_Bloom_RestoreScene();
			assert_quad(0, vid.height - size, size, vid.height,
					0, 0, (float)size / screen_tex_w, (float)size / screen_tex_h);

			/* A resolved scene never reached the window: present all of it. */
			bloom_scene_resolved = true;
			R_Bloom_RestoreScene();
			assert(!memcmp(whole, vertices, sizeof(whole)));
			bloom_scene_resolved = false;
		}
	}
	puts("bloom: whole-window capture, view sub-rect sampling and border-safe restores pass");
	return 0;
}
