/*
 * Copyright (C) 1997-2001 Id Software, Inc.
 * Copyright (C) KMQuake2 fog handling (Knightmare)
 * Copyright (C) 2026      yquake2-ppc port — cvar-driven adaptation
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or (at
 * your option) any later version.
 *
 * =======================================================================
 *
 * Cvar-driven GL_FOG enable/disable for the GL1 fixed-function renderer.
 * Adapted from KMQuake2 reference/kmquake2/renderer/r_fog.c — original
 * was game-DLL-driven (R_SetFogVars called by game code); here we surface
 * every parameter as a cvar so per-machine autoexec can opt in/out and
 * tune density and range. GL_FOG is fixed-function; works on every GPU
 * in the fleet including the Rage 128.
 *
 * Enable per frame in R_RenderView (after R_SetupGL, before R_DrawWorld);
 * disable at the end of R_RenderView (before the 2D HUD pass). Anything
 * drawn in the 3D pass — world, entities, particles, alpha surfaces —
 * receives fog. The 2D HUD does not.
 *
 * =======================================================================
 */

#include "header/local.h"

cvar_t *gl_fog;
cvar_t *gl_fog_mode;
cvar_t *gl_fog_density;
cvar_t *gl_fog_start;
cvar_t *gl_fog_end;
cvar_t *gl_fog_red;
cvar_t *gl_fog_green;
cvar_t *gl_fog_blue;

static const GLenum fog_modes[3] = { GL_LINEAR, GL_EXP, GL_EXP2 };

void
R_SetFog(void)
{
	GLfloat color[4];
	int mode_idx;

	if (!gl_fog || !gl_fog->value)
	{
		return;
	}

	mode_idx = (int)gl_fog_mode->value;
	if (mode_idx < 0 || mode_idx > 2)
	{
		mode_idx = 0;
	}

	color[0] = gl_fog_red->value;
	color[1] = gl_fog_green->value;
	color[2] = gl_fog_blue->value;
	color[3] = 1.0f;

	qglFogi(GL_FOG_MODE, fog_modes[mode_idx]);
	qglFogfv(GL_FOG_COLOR, color);

	if (fog_modes[mode_idx] == GL_LINEAR)
	{
		qglFogf(GL_FOG_START, gl_fog_start->value);
		qglFogf(GL_FOG_END, gl_fog_end->value);
	}
	else
	{
		qglFogf(GL_FOG_DENSITY, gl_fog_density->value / 10000.0f);
	}

	qglHint(GL_FOG_HINT, GL_NICEST);
	qglEnable(GL_FOG);
}

void
R_UnsetFog(void)
{
	if (!gl_fog || !gl_fog->value)
	{
		return;
	}
	qglDisable(GL_FOG);
}

void
R_RegisterFogCvars(void)
{
	gl_fog         = ri.Cvar_Get("gl_fog",         "0",    CVAR_ARCHIVE);
	gl_fog_mode    = ri.Cvar_Get("gl_fog_mode",    "0",    CVAR_ARCHIVE);
	gl_fog_density = ri.Cvar_Get("gl_fog_density", "50",   CVAR_ARCHIVE);
	gl_fog_start   = ri.Cvar_Get("gl_fog_start",   "64",   CVAR_ARCHIVE);
	gl_fog_end     = ri.Cvar_Get("gl_fog_end",     "2048", CVAR_ARCHIVE);
	gl_fog_red     = ri.Cvar_Get("gl_fog_red",     "0.5",  CVAR_ARCHIVE);
	gl_fog_green   = ri.Cvar_Get("gl_fog_green",   "0.5",  CVAR_ARCHIVE);
	gl_fog_blue    = ri.Cvar_Get("gl_fog_blue",    "0.55", CVAR_ARCHIVE);
}
