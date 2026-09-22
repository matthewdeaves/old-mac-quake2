/* State/rectangle checks on the production experimental resolve path. */
#include <assert.h>
#include "../yquake2/src/refresh/r_scene.c"

viddef_t vid;
refdef_t r_newrefdef;
refimport_t ri;
static GLuint read_target, draw_target;
static int blits, drains;
static GLboolean scissor_on;
void R_ApplyGLBuffer(void) { drains++; }
static void APIENTRY bind(GLenum target, GLuint id)
{
	if (target != SC_DRAW_FRAMEBUFFER) read_target = id;
	if (target != SC_READ_FRAMEBUFFER) draw_target = id;
}
static void APIENTRY attach(GLenum target, GLenum attachment, GLenum type, GLuint tex, GLint level)
{
	assert(target == SC_DRAW_FRAMEBUFFER && draw_target == resolve_fbo);
	assert(attachment == SC_COLOR_ATTACHMENT && type == GL_TEXTURE_2D);
	assert(tex == TEXNUM_BLOOMSCREEN && level == 0);
}
static GLenum APIENTRY status(GLenum target) { assert(target == SC_DRAW_FRAMEBUFFER); return SC_COMPLETE; }
static void APIENTRY draw(GLenum target) { assert(target == SC_COLOR_ATTACHMENT); }
static GLboolean APIENTRY enabled(GLenum cap) { assert(cap == GL_SCISSOR_TEST); return scissor_on; }
static void APIENTRY disable(GLenum cap) { assert(cap == GL_SCISSOR_TEST); scissor_on = false; }
static void APIENTRY enable(GLenum cap) { assert(cap == GL_SCISSOR_TEST); scissor_on = true; }
static GLenum APIENTRY error(void) { return GL_NO_ERROR; }
static void print(int level, char *format, ...) { (void)level; (void)format; }
static void fatal(int level, char *format, ...) { (void)level; (void)format; abort(); }
static void APIENTRY blit(GLint x0, GLint y0, GLint x1, GLint y1,
	GLint u0, GLint v0, GLint u1, GLint v1, GLbitfield mask, GLenum filter)
{
	assert(read_target == scene_fbo && !scissor_on);
	assert(!x0 && !y0 && !u0 && !v0);
	assert(x1 == vid.width && u1 == x1 && y1 == vid.height && v1 == y1);
	assert(mask == GL_COLOR_BUFFER_BIT && filter == GL_NEAREST);
	blits++;
}
__typeof__(qglDrawBuffer) qglDrawBuffer = draw;
__typeof__(qglIsEnabled) qglIsEnabled = enabled;
__typeof__(qglDisable) qglDisable = disable;
__typeof__(qglEnable) qglEnable = enable;
__typeof__(qglGetError) qglGetError = error;

int main(void)
{
	int view, clipped;
	assert(R_SceneHasExtension("GL_EXT_framebuffer_blit", "GL_EXT_framebuffer_blit"));
	assert(R_SceneHasExtension("first GL_EXT_framebuffer_blit last", "GL_EXT_framebuffer_blit"));
	assert(!R_SceneHasExtension("XGL_EXT_framebuffer_blit GL_EXT_framebuffer_blitX", "GL_EXT_framebuffer_blit"));
	scBindFramebuffer = bind; scFramebufferTexture2D = attach;
	scCheckFramebufferStatus = status; scBlitFramebuffer = blit;
	ri.Con_Printf = print; ri.Sys_Error = fatal;
	scene_fbo = 1; resolve_fbo = 2;
	vid.width = 1920; vid.height = 1080;
	R_SceneBegin(); R_ScenePresent(); assert(!drains && !blits);
	assert(!R_SceneResolveBloom());
	scene_ready = true;
	for (view = 0; view < 5; view++) for (clipped = 0; clipped < 2; clipped++)
	{
		r_newrefdef.x = view == 1 ? 32 : 0;
		r_newrefdef.y = view == 2 ? 32 : 0;
		r_newrefdef.width = view == 3 ? 1600 : vid.width;
		r_newrefdef.height = view == 4 ? 900 : vid.height;
		scissor_on = clipped; blits = 0;
		R_SceneBegin(); assert(scene_active && read_target == 1 && draw_target == 1);
		assert(R_SceneResolveBloom() == (view == 0));
		if (view) assert(scene_active && blits == 0);
		R_ScenePresent();
		assert(!scene_active && !read_target && !draw_target && blits == 1);
		assert(scissor_on == clipped);
		R_ScenePresent(); assert(blits == 1);
	}
	puts("scene: disabled path, full/reduced view, one resolve, binding and scissor restoration pass");
	return 0;
}
