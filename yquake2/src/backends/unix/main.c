/*
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
 * This file is the starting point of the program and implements
 * the main loop
 *
 * =======================================================================
 */

#include <fcntl.h>
#include <locale.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../../common/header/common.h"
#include "header/unix.h"

#if defined(__APPLE__) && !defined(DEDICATED_ONLY)
#include <SDL/SDL.h>
#endif

/* arm64 ONLY. PowerPC and Intel link a real SDL 1.2, whose SDLMain.m already
 * does this chdir, so they need none of it; and the 10.3/10.4 SDKs declare
 * _NSGetExecutablePath with an `unsigned long *` second argument rather than
 * `uint32_t *`, and have no PATH_MAX in scope here, so compiling it there just
 * breaks the PowerPC build for no gain. */
#if defined(__APPLE__) && (defined(__aarch64__) || defined(__arm64__))
#include <mach-o/dyld.h>
#include <limits.h>
#include <libgen.h>

/*
 * Put the process in the directory that holds the .app bundle.
 *
 * Quake II loads its renderer from basedir, and basedir defaults to "." (see
 * VID_LoadRefresh in backends/generic/vid.c):
 *
 *     path = Cvar_Get("basedir", ".", CVAR_NOSET)->string;
 *     snprintf(fn, MAX_OSPATH, "%s/%s", path, name);
 *
 * so the working directory decides whether ref_gl.so is found at all. Launched
 * from Finder the working directory is "/", so it looks for /ref_gl.so, fails,
 * and every entry in the renderer export table `re` stays NULL. Nothing reports
 * an error: the engine runs on, spinning at 100% CPU, until SCR_UpdateScreen
 * calls through the table and jumps to address 0.
 *
 * SDL 1.2's SDLMain.m already does this chdir, which is why PowerPC and Intel
 * were fine. The arm64 slice links sdl12-compat instead, and that does not use
 * SDL 1.2's Cocoa entry point, so setupWorkingDirectory never ran and Quake II
 * could only start from a terminal already sitting in the game folder.
 *
 * Doing it here rather than relying on any SDL main hook makes it true for
 * every architecture and every way of launching. Only applied when the
 * executable really is inside a .app; a plain command-line run is left alone so
 * `./quake2` from some other directory still behaves as the user asked.
 */
static void
OSX_ChdirToBundleParent(void)
{
	char exe[PATH_MAX];
	uint32_t size = sizeof(exe);
	char *p;

	if (_NSGetExecutablePath(exe, &size) != 0)
	{
		return;         /* path longer than PATH_MAX; leave the cwd alone */
	}

	/* .../Foo.app/Contents/MacOS/quake2 -> strip four components */
	p = realpath(exe, NULL);
	if (p == NULL)
	{
		return;
	}

	{
		char *dir = p;
		int i;

		for (i = 0; i < 4; i++)
		{
			char *slash = strrchr(dir, '/');

			if (slash == NULL)
			{
				free(p);
				return;
			}

			*slash = '\0';
		}

		/* Only move if we really came out of a bundle. */
		if (strstr(p, ".app") != NULL || strstr(exe, ".app/Contents/MacOS/") != NULL)
		{
			if (chdir(dir) != 0)
			{
				printf("Quake II: could not chdir to %s\n", dir);
			}
		}
	}

	free(p);
}
#endif /* __APPLE__ && arm64 */

int
main(int argc, char **argv)
{
	int time, oldtime, newtime;

#if defined(__APPLE__) && (defined(__aarch64__) || defined(__arm64__))
	OSX_ChdirToBundleParent();
#endif

	/* register signal handler */
	registerHandler();

	/* Prevent running Quake II as root. Only very mad
	   minded or stupid people even think about it. :) */
	if (getuid() == 0)
	{
		printf("Quake II shouldn't be run as root! Backing out to save your ass. If\n");
		printf("you really know what you're doing, edit src/unix/main.c and remove\n");
		printf("this check. But don't complain if Quake II eats your dog afterwards!\n");

		return 1;
	}

	/* Enforce the real UID to
	   prevent setuid crap */
	if (getuid() != geteuid())
	{
		printf("The effective UID is not the real UID! Your binary is probably marked\n");
		printf("'setuid'. That is not good idea, please fix it :) If you really know\n");
		printf("what you're doin edit src/unix/main.c and remove this check. Don't\n");
		printf("complain if Quake II eats your dog afterwards!\n");

		return 1;
	}

	/* enforce C locale */
	setenv("LC_ALL", "C", 1);

	printf("\nYamagi Quake II v%s\n", VERSION);
	printf("=====================\n\n");

#ifndef DEDICATED_ONLY
	printf("Client build options:\n");
#ifdef CDA
	printf(" + CD audio\n");
#else
	printf(" - CD audio\n");
#endif
#ifdef OGG
	printf(" + OGG/Vorbis\n");
#else
	printf(" - OGG/Vorbis\n");
#endif
#ifdef USE_OPENAL
	printf(" + OpenAL audio\n");
#else
	printf(" - OpenAL audio\n");
#endif
#ifdef ZIP
	printf(" + Zip file support\n");
#else
	printf(" - Zip file support\n");
#endif
#endif

	printf("Platform: %s\n", BUILDSTRING);
	printf("Architecture: %s\n", CPUSTRING);

	/* Seed PRNG */
	randk_seed();

	/* Initialze the game */
	Qcommon_Init(argc, argv);

	/* Do not delay reads on stdin*/
	fcntl(fileno(stdin), F_SETFL, fcntl(fileno(stdin), F_GETFL, NULL) | FNDELAY);

	oldtime = Sys_Milliseconds();

	/* The legendary Quake II mainloop */
	while (1)
	{
		/* find time spent rendering last frame */
		do
		{
			newtime = Sys_Milliseconds();
			time = newtime - oldtime;
		}
		while (time < 1);

		Qcommon_Frame(time);
		oldtime = newtime;
	}

	return 0;
}

