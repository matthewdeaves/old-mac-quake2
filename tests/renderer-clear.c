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

/* Name-keyed cvar table for R_ApplyCapabilityTier (#79). */
static const char *tier_names[] = {"q2_autotier", "q2_overlay_gpu", "gl_bloom",
	"gl_stencilshadow", "gl_glows", "gl_trans_lighting", "gl_caustics"};
enum { T_TIER, T_EXPECT, T_BLOOM, T_SHADOW, T_GLOWS, T_TRANS, T_CAUSTICS, T_COUNT };
static cvar_t tier_vars[T_COUNT];
static char tier_strings[T_COUNT][64];
static int tier_index(const char *name)
{
	int i;
	for (i = 0; i < T_COUNT; i++)
		if (!strcmp(name, tier_names[i])) return i;
	assert(!"capability tier touched an unexpected cvar");
	return -1;
}
static cvar_t *tier_set(char *name, char *value)
{
	int i = tier_index(name);
	snprintf(tier_strings[i], sizeof(tier_strings[i]), "%s", value);
	tier_vars[i].string = tier_strings[i];
	tier_vars[i].value = (float)atof(value);
	return &tier_vars[i];
}
static cvar_t *tier_get(char *name, char *value, int flags)
{
	(void)value; (void)flags;
	return &tier_vars[tier_index(name)];
}
/* tier, expect, renderer; then 1/0 for bloom, shadow, glows, trans, caustics,
 * where the "before" state is all 1 except glows/trans/caustics at 7 so an
 * untouched cvar is distinguishable from one set to 1. */
static void tier_case(const char *tier, const char *expect, const char *renderer,
		int bloom, int shadow, int glows, int trans, int caustics)
{
	int i;
	for (i = 0; i < T_COUNT; i++) tier_set((char *)tier_names[i], "1");
	tier_set("q2_autotier", (char *)tier);
	tier_set("q2_overlay_gpu", (char *)expect);
	tier_set("gl_glows", "7"); tier_set("gl_trans_lighting", "7"); tier_set("gl_caustics", "7");
	R_ApplyCapabilityTier(renderer);
	assert(tier_vars[T_BLOOM].value == bloom && tier_vars[T_SHADOW].value == shadow);
	assert(tier_vars[T_GLOWS].value == glows && tier_vars[T_TRANS].value == trans);
	assert(tier_vars[T_CAUSTICS].value == caustics);
	/* Always consumed, so a vid_restart cannot re-apply it. */
	assert(tier_vars[T_TIER].value == 0);
	R_ApplyCapabilityTier(renderer);
	assert(tier_vars[T_BLOOM].value == bloom && tier_vars[T_GLOWS].value == glows);
}

static void test_capability_tier(void)
{
	ri.Cvar_Get = tier_get;
	ri.Cvar_Set = tier_set;
	ri.Con_Printf = print_option;
	/* No bundle layers ran (-noarchautoexec): nothing is touched. */
	tier_case("0", "", "ati radeon 9200 opengl engine", 1, 1, 7, 7, 7);
	/* Mapped, live GPU matches the overlay: the measured profile stands. */
	tier_case("2", "radeon 9200", "ati radeon 9200 opengl engine", 1, 1, 7, 7, 7);
	tier_case("2", "rage 128", "ati rage 128 opengl engine", 1, 1, 7, 7, 7);
	/* Mapped, a different GPU (e.g. an iMac G5 with a GeForce FX 5200). */
	tier_case("2", "radeon 9600", "nvidia geforce fx 5200 opengl engine", 0, 0, 1, 1, 1);
	tier_case("2", "radeon 9600", "ati rage 128 opengl engine", 0, 0, 0, 1, 1);
	tier_case("2", "gma 950", "apple m5", 0, 0, 0, 0, 0);
	/* Mapped but undeclared: cannot be verified, so it falls back too. */
	tier_case("2", "", "ati radeon 9200 opengl engine", 0, 0, 1, 1, 1);
	/* Unmapped: the #32 behaviour, extras untouched. */
	tier_case("1", "", "nvidia geforce 9400 opengl engine", 1, 1, 1, 1, 1);
	tier_case("1", "", "ati rage 128 opengl engine", 1, 1, 7, 1, 1);
	tier_case("1", "", "apple m5", 1, 1, 7, 7, 7);
	puts("capability tier: probe on mapped and unmapped machines, overlay kept only on a GPU match");
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
	test_capability_tier();
	return 0;
}
