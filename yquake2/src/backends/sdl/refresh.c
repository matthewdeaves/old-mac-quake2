/*
 * Copyright (C) 2010 Yamagi Burmeister
 * Copyright (C) 1997-2001 Id Software, Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or (at
 * your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 *
 * See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
 * 02111-1307, USA.
 *
 * =======================================================================
 *
 * This file implements an OpenGL context via SDL
 *
 * =======================================================================
 */

#include "../../refresh/header/local.h"
#include "../generic/header/glwindow.h"
#if defined(__APPLE__)
#include <OpenGL/gl.h>
#include <sys/sysctl.h>
#include <string.h>
#else
#include <GL/gl.h>
#endif

#ifdef _WIN32
#include <SDL/SDL.h>
#elif defined(__APPLE__)
#include <SDL/SDL.h>
#else
#include <SDL.h>
#endif

/* The window icon */
#include "icon/q2icon.xbm"

/* X.org stuff */
#ifdef X11GAMMA
 #include <X11/Xos.h>
 #include <X11/Xlib.h>
 #include <X11/Xutil.h>
 #include <X11/extensions/xf86vmode.h>
#endif

SDL_Surface *surface;
glwstate_t glw_state;
qboolean have_stencil = false;

char *displayname = NULL;
int screen = -1;

/* Desktop resolution captured once at SDL video init (before the first
 * SDL_SetVideoMode), used by the vid_desktopfullscreen same-mode capture
 * path. 0 until captured. See GLimp_Init / GLimp_InitGraphics. */
static int glimp_desktop_width = 0;
static int glimp_desktop_height = 0;

/*
 * True on hardware whose GPU driver hard-hangs the whole OS on a non-native
 * fullscreen video-mode SWITCH, so fullscreen MUST be a same-mode desktop
 * capture. Detected via hw.model (available before any GL call, so it can
 * protect the very first VID_Init — unlike the GL renderer string, which
 * doesn't exist until after the dangerous mode set). Currently the iMac G5
 * family (ATI R300 / Radeon 9600 on Leopard). Forcing capture is harmless
 * on the NVIDIA-GPU variants of these models too (just native fullscreen),
 * so gating on the model alone is safe. Result cached. Non-Apple: always
 * false (the cvar still drives the optional capture path).
 */
static qboolean
GLimp_ForceDesktopFullscreen(void)
{
#if defined(__APPLE__)
	static int cached = -1;

	if (cached < 0)
	{
		char model[64];
		size_t len = sizeof(model);

		cached = 0;
		if (sysctlbyname("hw.model", model, &len, NULL, 0) == 0)
		{
			/* iMac G5 family: PowerMac8,1 / 8,2 (ALS) / 12,1 (iSight). */
			if (!strcmp(model, "PowerMac8,2") ||
					!strcmp(model, "PowerMac8,1") ||
					!strcmp(model, "PowerMac12,1"))
			{
				cached = 1;
			}
		}
	}

	return cached ? true : false;
#else
	return false;
#endif
}

#ifdef X11GAMMA
Display *dpy;
XF86VidModeGamma x11_oldgamma;
#endif

/*
 * Initialzes the SDL OpenGL context
 */
int
GLimp_Init(void)
{
	if (!SDL_WasInit(SDL_INIT_VIDEO))
	{
		char driverName[64];

		if (SDL_Init(SDL_INIT_VIDEO) == -1)
		{
			ri.Con_Printf(PRINT_ALL, "Couldn't init SDL video: %s.\n",
					SDL_GetError());
			return false;
		}

		SDL_VideoDriverName(driverName, sizeof(driverName) - 1);
		ri.Con_Printf(PRINT_ALL, "SDL video driver is \"%s\".\n", driverName);

		/* Capture the DESKTOP resolution now, before the first
		 * SDL_SetVideoMode. In SDL 1.2 SDL_GetVideoInfo()->current_w/h
		 * reports the desktop mode only until the first SetVideoMode, after
		 * which it reports the active surface. Stash it so the
		 * vid_desktopfullscreen path (GLimp_InitGraphics) can request a
		 * same-mode fullscreen capture at the panel's native resolution. */
		{
			const SDL_VideoInfo *vinfo = SDL_GetVideoInfo();
			if (vinfo && vinfo->current_w > 0 && vinfo->current_h > 0)
			{
				glimp_desktop_width = vinfo->current_w;
				glimp_desktop_height = vinfo->current_h;
				ri.Con_Printf(PRINT_ALL, "Desktop is %dx%d.\n",
						glimp_desktop_width, glimp_desktop_height);
			}
		}
	}

	return true;
}

/*
 * Sets the window icon
 */
static void
SetSDLIcon()
{
	SDL_Surface *icon;
	SDL_Color color;
	Uint8 *ptr;
	int i;
	int mask;

	icon = SDL_CreateRGBSurface(SDL_SWSURFACE,
			q2icon_width, q2icon_height, 8,
			0, 0, 0, 0);

	if (icon == NULL)
	{
		return;
	}

	SDL_SetColorKey(icon, SDL_SRCCOLORKEY, 0);

	color.r = 255;
	color.g = 255;
	color.b = 255;

	SDL_SetColors(icon, &color, 0, 1);

	color.r = 0;
	color.g = 16;
	color.b = 0;

	SDL_SetColors(icon, &color, 1, 1);

	ptr = (Uint8 *)icon->pixels;

	for (i = 0; i < sizeof(q2icon_bits); i++)
	{
		for (mask = 1; mask != 0x100; mask <<= 1)
		{
			*ptr = (q2icon_bits[i] & mask) ? 1 : 0;
			ptr++;
		}
	}

	SDL_WM_SetIcon(icon, NULL);
	SDL_FreeSurface(icon);
}

/*
 * Sets the hardware gamma
 */
#ifdef X11GAMMA
void
UpdateHardwareGamma(void)
{
	float gamma;
	XF86VidModeGamma x11_gamma;

	gamma = vid_gamma->value;

	x11_gamma.red = gamma;
	x11_gamma.green = gamma;
	x11_gamma.blue = gamma;

	XF86VidModeSetGamma(dpy, screen, &x11_gamma);

	/* This forces X11 to update the gamma tables */
	XF86VidModeGetGamma(dpy, screen, &x11_gamma);
}

#else
void
UpdateHardwareGamma(void)
{
	float gamma;

	gamma = (vid_gamma->value);
	SDL_SetGamma(gamma, gamma, gamma);
}
#endif

/*
 * Initializes the OpenGL window
 */
static qboolean
GLimp_InitGraphics(qboolean fullscreen)
{
	int counter = 0;
	int flags;
	int stencil_bits;
	char title[24];

	/* vid_desktopfullscreen: satisfy a fullscreen request at the captured
	 * DESKTOP resolution (a same-mode display CAPTURE) instead of switching
	 * the video mode to a requested non-native size. This auto-selects the
	 * panel's native res and is the ONLY fullscreen path the ATI R300
	 * (Radeon 9600 / iMac G5 on Leopard) driver survives — a non-native
	 * mode switch hard-hangs the whole OS. Harmless elsewhere (default off).
	 *
	 * The cvar is set by the per-machine autoexec, but that runs AFTER this
	 * initial VID_Init — so a stale config.cfg with vid_fullscreen 1 +
	 * vid_desktopfullscreen 0 could still drive a mode switch on the very
	 * first frame, before the overlay loads. GLimp_ForceDesktopFullscreen()
	 * closes that hole: on the iMac G5 hardware (detected pre-GL via
	 * hw.model) the capture is forced for EVERY fullscreen request,
	 * independent of any cvar / config — defense in depth against a wedge
	 * that needs a physical power-cycle to recover.
	 * Done before the surface-size early-out below so it compares correctly. */
	{
		extern cvar_t *vid_desktopfullscreen;
		int want_capture = (vid_desktopfullscreen && vid_desktopfullscreen->value)
				|| GLimp_ForceDesktopFullscreen();
		if (fullscreen && want_capture &&
				glimp_desktop_width > 0 && glimp_desktop_height > 0)
		{
			vid.width = glimp_desktop_width;
			vid.height = glimp_desktop_height;
		}
	}

	if (surface && (surface->w == vid.width) && (surface->h == vid.height))
	{
		/* Are we running fullscreen? */
		int isfullscreen = (surface->flags & SDL_FULLSCREEN) ? 1 : 0;

		/* We should, but we don't */
		if (fullscreen != isfullscreen)
		{
			SDL_WM_ToggleFullScreen(surface);
		}

		/* Do we now? */
		isfullscreen = (surface->flags & SDL_FULLSCREEN) ? 1 : 0;

		if (fullscreen == isfullscreen)
		{
			return true;
		}
	}

	/* Is the surface used? */
	if (surface)
	{
		SDL_FreeSurface(surface);
	}

	/* Create the window */
	ri.Vid_NewWindow(vid.width, vid.height);

	SDL_GL_SetAttribute(SDL_GL_RED_SIZE, 8);
	SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE, 8);
	SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE, 8);
	SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
	SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
	SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);

	/* MSAA via SDL 1.2 — request multisample if the cvar is set.
	 * 0 = off; 2/4/8/16 = N-sample MSAA. The SDL_SetVideoMode call
	 * below will succeed even if the driver can't honour the request
	 * (silently drops to the next-lower available count), but a
	 * machine without GL_ARB_multisample will get plain antialiasing-
	 * off output. Per-machine defaults via autoexec cvar. */
	{
		extern cvar_t *gl_msaa_samples;
		if (gl_msaa_samples && (int)gl_msaa_samples->value > 0)
		{
			SDL_GL_SetAttribute(SDL_GL_MULTISAMPLEBUFFERS, 1);
			SDL_GL_SetAttribute(SDL_GL_MULTISAMPLESAMPLES,
					(int)gl_msaa_samples->value);
		}
	}

	/* Initiate the flags */
	flags = SDL_OPENGL;

	if (fullscreen)
	{
		flags |= SDL_FULLSCREEN;
	}

	/* Set the icon */
	SetSDLIcon();

	/* Vsync — explicitly set SWAP_CONTROL even when disabling. Apple's
	 * Quartz / OpenGL framework defaults to vsync ON after a fresh boot
	 * on some Macs; the previous code only SET swap-control to 1 when
	 * gl_swapinterval was non-zero, leaving the cvar=0 case to inherit
	 * whatever the system happened to default to. On mini-g4 post-reboot
	 * that defaulted to ON, capping fps at 60 Hz (96 → 56 fps for demo1
	 * 1024). Explicit 0 in the off case forces tearing instead of cap. */
	SDL_GL_SetAttribute(SDL_GL_SWAP_CONTROL,
			gl_swapinterval->value ? 1 : 0);

	while (1)
	{
		if ((surface = SDL_SetVideoMode(vid.width, vid.height, 0, flags)) == NULL)
		{
			if (counter == 1)
			{
				ri.Sys_Error(ERR_FATAL, "Failed to revert to gl_mode 5. Exiting...\n");
				return false;
			}

			ri.Con_Printf(PRINT_ALL, "SDL SetVideoMode failed: %s\n",
					SDL_GetError());
			ri.Con_Printf(PRINT_ALL, "Reverting to gl_mode 5 (640x480) and windowed mode.\n");

			/* Try to recover */
			ri.Cvar_SetValue("gl_mode", 5);
			ri.Cvar_SetValue("vid_fullscreen", 0);
			vid.width = 640;
			vid.height = 480;

			counter++;
			continue;
		}
		else
		{
			break;
		}
	}

	/* Initialize the stencil buffer */
	if (!SDL_GL_GetAttribute(SDL_GL_STENCIL_SIZE, &stencil_bits))
	{
		ri.Con_Printf(PRINT_ALL, "Got %d bits of stencil.\n", stencil_bits);

		if (stencil_bits >= 1)
		{
			have_stencil = true;
		}
	}

	/* Initialize hardware gamma */
#ifdef X11GAMMA
	if ((dpy = XOpenDisplay(displayname)) == NULL)
	{
		ri.Con_Printf(PRINT_ALL, "Unable to open display.\n");
	}
	else
	{
		if (screen == -1)
		{
			screen = DefaultScreen(dpy);
		}

		gl_state.hwgamma = true;
		vid_gamma->modified = true;

		XF86VidModeGetGamma(dpy, screen, &x11_oldgamma);

		ri.Con_Printf(PRINT_ALL, "Using hardware gamma via X11.\n");
	}
#else
	gl_state.hwgamma = true;
	vid_gamma->modified = true;
	ri.Con_Printf(PRINT_ALL, "Using hardware gamma via SDL.\n");
#endif

	/* Window title */
	snprintf(title, sizeof(title), "Yamagi Quake II %s", VERSION);
	SDL_WM_SetCaption(title, title);

	/* No cursor */
	SDL_ShowCursor(0);

	return true;
}

/*
 * Swaps the buffers to show the new frame
 */
void
GLimp_EndFrame(void)
{
	SDL_GL_SwapBuffers();
}

/*
 * Changes the video mode
 */
int
GLimp_SetMode(int *pwidth, int *pheight, int mode, qboolean fullscreen)
{
	ri.Con_Printf(PRINT_ALL, "setting mode %d:", mode);

	/* mode -1 is not in the vid mode table - so we keep the values in pwidth
	   and pheight and don't even try to look up the mode info */
	if ((mode != -1) && !ri.Vid_GetModeInfo(pwidth, pheight, mode))
	{
		ri.Con_Printf(PRINT_ALL, " invalid mode\n");
		return rserr_invalid_mode;
	}

	ri.Con_Printf(PRINT_ALL, " %d %d\n", *pwidth, *pheight);

	if (!GLimp_InitGraphics(fullscreen))
	{
		return rserr_invalid_mode;
	}

	return rserr_ok;
}

/*
 * Shuts the SDL render backend down
 */
void
GLimp_Shutdown(void)
{
	/* Clear the backbuffer and make it
	   current. This may help some broken
	   video drivers like the AMD Catalyst
	   to avoid artifacts in unused screen
	   areas, */
	qglClearColor(0.0, 0.0, 0.0, 0.0);
	qglClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	GLimp_EndFrame();

	if (surface)
	{
		SDL_FreeSurface(surface);
	}

	surface = NULL;

	if (SDL_WasInit(SDL_INIT_EVERYTHING) == SDL_INIT_VIDEO)
	{
		SDL_Quit();
	}
	else
	{
		SDL_QuitSubSystem(SDL_INIT_VIDEO);
	}

#ifdef X11GAMMA
	if (gl_state.hwgamma == true)
	{
		XF86VidModeSetGamma(dpy, screen, &x11_oldgamma);

		/* This forces X11 to update the gamma tables */
		XF86VidModeGetGamma(dpy, screen, &x11_oldgamma);
	}
#endif

	gl_state.hwgamma = false;
}

