/* Exercise the production clear path, including both z-trick phases. */
#include <assert.h>
#include "../yquake2/src/refresh/r_main.c"

qboolean have_stencil;
typedef struct {
	GLbitfield bits;
	int calls, stencil;
	GLenum depthfunc;
	double nearval, farval;
	float factor, units;
} observed_t;
static observed_t observed;
static void APIENTRY clear(GLbitfield bits) { observed.bits |= bits; observed.calls++; }
static void APIENTRY stencil(GLint value) { observed.stencil = value; }
static void APIENTRY depthfunc(GLenum value) { observed.depthfunc = value; }
static void APIENTRY depthrange(GLclampd nearval, GLclampd farval)
{ observed.nearval = nearval; observed.farval = farval; }
static void APIENTRY offset(GLfloat factor, GLfloat units)
{ observed.factor = factor; observed.units = units; }
__typeof__(qglClear) qglClear = clear;
__typeof__(qglClearStencil) qglClearStencil = stencil;
__typeof__(qglDepthFunc) qglDepthFunc = depthfunc;
__typeof__(qglDepthRange) qglDepthRange = depthrange;
__typeof__(qglPolygonOffset) qglPolygonOffset = offset;

static cvar_t *set_option(char *name, char *value)
{
	cvar_t *option;
	if (!strcmp(name, "gl_stencilshadow")) option = gl_stencilshadow;
	else { assert(!strcmp(name, "gl_clear_combined")); option = gl_clear_combined; }
	option->value = atof(value);
	return option;
}
static void print_option(int level, char *format, ...)
{ (void)level; (void)format; }

static void test_shadow_defaults(void)
{
	const char *renderers[] = {"nvidia geforce 9400 opengl engine",
		"intel gma 950", "ati rage 128", "ati radeon 9200", "unknown", ""};
	int gpu, shadow, combined;
	ri.Cvar_Set = set_option;
	ri.Con_Printf = print_option;
	for (gpu = 0; gpu < 6; gpu++)
		for (shadow = -1; shadow <= 1; shadow++)
			for (combined = -1; combined <= 1; combined++)
			{
				gl_stencilshadow->value = shadow;
				gl_clear_combined->value = combined;
				R_ApplyShadowDefaults(renderers[gpu]);
				assert(gl_stencilshadow->value == (shadow < 0 ? gpu == 0 : shadow));
				assert(gl_clear_combined->value == (combined < 0 ? gpu == 0 : combined));
				/* Restart must not reinterpret resolved or explicit values. */
				R_ApplyShadowDefaults("unknown");
				assert(gl_stencilshadow->value == (shadow < 0 ? gpu == 0 : shadow));
				assert(gl_clear_combined->value == (combined < 0 ? gpu == 0 : combined));
			}
	puts("shadow defaults: measured GPU only, explicit overrides and restart preservation pass");
}

int main(void)
{
	cvar_t vars[6] = {{0}};
	int mask, phase, mode;
	observed_t reference[2];
	gl_clear = vars;
	gl_ztrick = vars + 1;
	gl_shadows = vars + 2;
	gl_stencilshadow = vars + 3;
	gl_zfix = vars + 4;
	gl_clear_combined = vars + 5;
	for (mask = 0; mask < 64; mask++)
	{
		gl_clear->value = !!(mask & 1);
		gl_ztrick->value = !!(mask & 2);
		gl_shadows->value = !!(mask & 4);
		gl_stencilshadow->value = !!(mask & 8);
		gl_zfix->value = !!(mask & 16);
		have_stencil = !!(mask & 32);
		for (mode = 0; mode < 2; mode++)
		{
			gl_clear_combined->value = mode;
			for (phase = 0; phase < 2; phase++)
			{
				memset(&observed, 0, sizeof(observed));
				R_Clear();
				if (!mode) reference[phase] = observed;
				else
				{
					assert(observed.calls <= 1);
					assert(observed.calls <= reference[phase].calls);
					observed.calls = reference[phase].calls;
					assert(!memcmp(&observed, &reference[phase], sizeof(observed)));
				}
			}
		}
	}
	puts("clear: all 64 state combinations and both depth phases preserve buffer/state results");
	test_shadow_defaults();
	return 0;
}
