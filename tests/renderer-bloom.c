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

int main(void)
{
	cvar_t fast = {0};
	float original[4][4];
	int view, size;
	gl_bloom_fastrestore = &fast;
	vid.width = 1920; vid.height = 1080;
	screen_tex_w = screen_tex_h = 2048;
	for (view = 0; view < 5; view++)
	{
		r_newrefdef.x = view == 1 ? 32 : 0;
		r_newrefdef.y = view == 2 ? 32 : 0;
		r_newrefdef.width = view == 3 ? 1600 : vid.width;
		r_newrefdef.height = view == 4 ? 900 : vid.height;
		v_x = r_newrefdef.x;
		v_y = vid.height - r_newrefdef.height - r_newrefdef.y;
		v_w = r_newrefdef.width; v_h = r_newrefdef.height;
		scr_tcw = (float)v_w / screen_tex_w;
		scr_tch = (float)v_h / screen_tex_h;
		for (size = 64; size <= 512; size *= 2)
		{
			BLOOM_SIZE = size;
			fast.value = 0;
			R_Bloom_RestoreScene();
			memcpy(original, vertices, sizeof(original));
			fast.value = 1;
			R_Bloom_RestoreScene();
			if (view) assert(!memcmp(original, vertices, sizeof(original)));
			else
			{
				assert(vertices[0][0] == 0 && vertices[0][1] == vid.height - size);
				assert(vertices[2][0] == size && vertices[2][1] == vid.height);
				assert(vertices[0][3] == (float)size / screen_tex_h);
				assert(vertices[2][2] == (float)size / screen_tex_w);
				assert(vertices[1][2] == 0 && vertices[1][3] == 0);
			}
		}
	}
	puts("bloom: full-view workspace mapping and reduced/offset fallback pass");
	return 0;
}
