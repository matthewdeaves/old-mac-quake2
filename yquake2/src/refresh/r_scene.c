/*
 * Experimental resolve-once scene target. Off by default.
 * Distributed under the GNU General Public License, version 2 or later;
 * see LICENSE for the license and warranty disclaimer.
 */
#include "header/local.h"

cvar_t *gl_scene_resolve;

/* Local tokens keep the old SDK headers usable. */
#define SC_FRAMEBUFFER 0x8D40
#define SC_RENDERBUFFER 0x8D41
#define SC_READ_FRAMEBUFFER 0x8CA8
#define SC_DRAW_FRAMEBUFFER 0x8CA9
#define SC_COLOR_ATTACHMENT 0x8CE0
#define SC_DEPTH_ATTACHMENT 0x8D00
#define SC_STENCIL_ATTACHMENT 0x8D20
#define SC_COMPLETE 0x8CD5
#define SC_DEPTH24_STENCIL8 0x88F0
#define SC_RENDERBUFFER_SAMPLES 0x8CAB

static void (APIENTRY *scGenFramebuffers)(GLsizei, GLuint *);
static void (APIENTRY *scDeleteFramebuffers)(GLsizei, const GLuint *);
static void (APIENTRY *scBindFramebuffer)(GLenum, GLuint);
static GLenum (APIENTRY *scCheckFramebufferStatus)(GLenum);
static void (APIENTRY *scFramebufferRenderbuffer)(GLenum, GLenum, GLenum, GLuint);
static void (APIENTRY *scFramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint);
static void (APIENTRY *scGenRenderbuffers)(GLsizei, GLuint *);
static void (APIENTRY *scDeleteRenderbuffers)(GLsizei, const GLuint *);
static void (APIENTRY *scBindRenderbuffer)(GLenum, GLuint);
static void (APIENTRY *scRenderbufferStorageMultisample)(GLenum, GLsizei, GLenum, GLsizei, GLsizei);
static void (APIENTRY *scGetRenderbufferParameteriv)(GLenum, GLenum, GLint *);
static void (APIENTRY *scBlitFramebuffer)(GLint, GLint, GLint, GLint,
	GLint, GLint, GLint, GLint, GLbitfield, GLenum);
static GLuint scene_fbo, resolve_fbo, scene_color, scene_depth;
static qboolean scene_ready, scene_active, scene_resolve_logged, scene_present_logged;

static qboolean
R_SceneHasExtension(const char *extensions, const char *name)
{
	const char *match = extensions;
	size_t length = strlen(name);
	while ((match = strstr(match, name)) != NULL)
	{
		if ((match == extensions || match[-1] == ' ') &&
			(match[length] == ' ' || match[length] == '\0')) return true;
		match += length;
	}
	return false;
}

void
R_SceneShutdown(void)
{
	if (scBindFramebuffer) scBindFramebuffer(SC_FRAMEBUFFER, 0);
	if (scene_fbo) scDeleteFramebuffers(1, &scene_fbo);
	if (resolve_fbo) scDeleteFramebuffers(1, &resolve_fbo);
	if (scene_color) scDeleteRenderbuffers(1, &scene_color);
	if (scene_depth) scDeleteRenderbuffers(1, &scene_depth);
	scene_fbo = resolve_fbo = scene_color = scene_depth = 0;
	scene_ready = scene_active = scene_resolve_logged = false;
	scene_present_logged = false;
}

qboolean
R_SceneInit(void)
{
	GLint samples, color_samples, depth_samples, default_samples, binding;
	const char *ext = gl_config.extensions_string;
	if (!gl_scene_resolve->value) return true;
	/* Explicit experimental mode fails closed rather than quietly dropping
	 * requested AA when the single-sample window cannot be backed by an FBO. */
	if (!R_SceneHasExtension(ext, "GL_EXT_framebuffer_object") ||
		!R_SceneHasExtension(ext, "GL_EXT_framebuffer_multisample") ||
		!R_SceneHasExtension(ext, "GL_EXT_framebuffer_blit") ||
		!R_SceneHasExtension(ext, "GL_EXT_packed_depth_stencil") ||
		gl_state.stereo_enabled || Q_stricmp(gl_drawbuffer->string, "GL_BACK"))
		goto failed;
#define SC_LOAD(name) do { sc##name = (void *)GetProcAddressGL("gl" #name "EXT"); if (!sc##name) goto failed; } while (0)
	SC_LOAD(GenFramebuffers);
	SC_LOAD(DeleteFramebuffers);
	SC_LOAD(BindFramebuffer);
	SC_LOAD(CheckFramebufferStatus);
	SC_LOAD(FramebufferRenderbuffer);
	SC_LOAD(FramebufferTexture2D);
	SC_LOAD(GenRenderbuffers);
	SC_LOAD(DeleteRenderbuffers);
	SC_LOAD(BindRenderbuffer);
	SC_LOAD(RenderbufferStorageMultisample);
	SC_LOAD(GetRenderbufferParameteriv);
	SC_LOAD(BlitFramebuffer);
#undef SC_LOAD
	qglGetIntegerv(0x8CA6, &binding);
	qglGetIntegerv(0x80A9, &default_samples);
	qglGetIntegerv(0x8D57, &samples); /* MAX_SAMPLES_EXT */
	if (binding || default_samples || gl_msaa_samples->value < 2 ||
		gl_msaa_samples->value > samples) goto failed;
	samples = (int)gl_msaa_samples->value;
	scGenFramebuffers(1, &scene_fbo);
	scGenFramebuffers(1, &resolve_fbo);
	scGenRenderbuffers(1, &scene_color);
	scGenRenderbuffers(1, &scene_depth);
	scBindFramebuffer(SC_FRAMEBUFFER, scene_fbo);
	scBindRenderbuffer(SC_RENDERBUFFER, scene_color);
	scRenderbufferStorageMultisample(SC_RENDERBUFFER, samples, GL_RGBA8, vid.width, vid.height);
	scGetRenderbufferParameteriv(SC_RENDERBUFFER, SC_RENDERBUFFER_SAMPLES, &color_samples);
	scFramebufferRenderbuffer(SC_FRAMEBUFFER, SC_COLOR_ATTACHMENT, SC_RENDERBUFFER, scene_color);
	scBindRenderbuffer(SC_RENDERBUFFER, scene_depth);
	scRenderbufferStorageMultisample(SC_RENDERBUFFER, samples, SC_DEPTH24_STENCIL8, vid.width, vid.height);
	scGetRenderbufferParameteriv(SC_RENDERBUFFER, SC_RENDERBUFFER_SAMPLES, &depth_samples);
	scFramebufferRenderbuffer(SC_FRAMEBUFFER, SC_DEPTH_ATTACHMENT, SC_RENDERBUFFER, scene_depth);
	scFramebufferRenderbuffer(SC_FRAMEBUFFER, SC_STENCIL_ATTACHMENT, SC_RENDERBUFFER, scene_depth);
	qglReadBuffer(SC_COLOR_ATTACHMENT);
	qglDrawBuffer(SC_COLOR_ATTACHMENT);
	if (scCheckFramebufferStatus(SC_FRAMEBUFFER) != SC_COMPLETE ||
		color_samples != samples || depth_samples != samples || qglGetError() != GL_NO_ERROR)
		goto failed;
	qglClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
	scBindRenderbuffer(SC_RENDERBUFFER, 0);
	scBindFramebuffer(SC_FRAMEBUFFER, 0);
	scene_ready = true;
	ri.Con_Printf(PRINT_ALL, "Scene resolve: %dx%d, requested %d, color/depth samples %d/%d, window samples %d\n",
		vid.width, vid.height, samples, color_samples, depth_samples, default_samples);
	return true;
failed:
	ri.Con_Printf(PRINT_ALL, "Scene resolve unavailable: experimental mode requires native SDL, EXT FBO/blit/MSAA/packed-depth and matching sample storage. Disable gl_scene_resolve.\n");
	R_SceneShutdown();
	return false;
}

void
R_SceneBegin(void)
{
	if (!scene_ready) return;
	R_ApplyGLBuffer();
	scBindFramebuffer(SC_FRAMEBUFFER, scene_fbo);
	scene_active = true;
}

/* Resolve a full viewport straight into bloom's existing texture. Other
 * views fall back to a full scene presentation plus the original bloom path. */
qboolean
R_SceneResolveBloom(void)
{
	GLboolean scissor;
	GLenum error;
	if (!scene_active || r_newrefdef.x || r_newrefdef.y ||
		r_newrefdef.width != vid.width || r_newrefdef.height != vid.height)
		return false;
	R_ApplyGLBuffer();
	scBindFramebuffer(SC_DRAW_FRAMEBUFFER, resolve_fbo);
	scFramebufferTexture2D(SC_DRAW_FRAMEBUFFER, SC_COLOR_ATTACHMENT, GL_TEXTURE_2D, TEXNUM_BLOOMSCREEN, 0);
	qglDrawBuffer(SC_COLOR_ATTACHMENT);
	if (scCheckFramebufferStatus(SC_DRAW_FRAMEBUFFER) != SC_COMPLETE)
		ri.Sys_Error(ERR_FATAL, "Scene resolve: incomplete bloom target");
	scissor = qglIsEnabled(GL_SCISSOR_TEST);
	qglDisable(GL_SCISSOR_TEST);
	scBlitFramebuffer(0, 0, vid.width, vid.height, 0, 0, vid.width, vid.height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
	if (!scene_resolve_logged)
	{
		error = qglGetError();
		ri.Con_Printf(PRINT_ALL, "Scene resolve: first bloom blit error 0x%x\n", error);
		if (error != GL_NO_ERROR) ri.Sys_Error(ERR_FATAL, "Scene resolve: blit failed");
		scene_resolve_logged = true;
	}
	if (scissor) qglEnable(GL_SCISSOR_TEST);
	scBindFramebuffer(SC_FRAMEBUFFER, 0);
	scene_active = false;
	return true;
}

void
R_ScenePresent(void)
{
	GLboolean scissor;
	GLenum error;
	if (!scene_active) return;
	R_ApplyGLBuffer();
	scBindFramebuffer(SC_DRAW_FRAMEBUFFER, 0);
	scissor = qglIsEnabled(GL_SCISSOR_TEST);
	qglDisable(GL_SCISSOR_TEST);
	scBlitFramebuffer(0, 0, vid.width, vid.height, 0, 0, vid.width, vid.height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
	if (!scene_present_logged)
	{
		error = qglGetError();
		ri.Con_Printf(PRINT_ALL, "Scene resolve: first presentation blit error 0x%x\n", error);
		if (error != GL_NO_ERROR) ri.Sys_Error(ERR_FATAL, "Scene resolve: presentation blit failed");
		scene_present_logged = true;
	}
	if (scissor) qglEnable(GL_SCISSOR_TEST);
	scBindFramebuffer(SC_FRAMEBUFFER, 0);
	scene_active = false;
}
