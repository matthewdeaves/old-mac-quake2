/*
 * Copyright (C) 2026 QuakeII PPC port
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or (at
 * your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * =======================================================================
 *
 * sysreport -- in-engine community spec + benchmark collector.
 *
 * The sibling of QuakeSpasm's `sysreport`: one console command runs the
 * canonical 3-demo x 3-run timedemo grid unattended, gathers the machine's
 * hardware specs (hw.model / CPU / RAM / GPU / storage via sysctl +
 * system_profiler on Apple), records the per-machine cvar settings the
 * benchmark ran under, and writes a self-contained report (+ a copy of the
 * console log covering all runs) to the user's Desktop to email back.
 *
 * Q2 specifics vs Q1: a demo is started with `demomap demoN.dm2` while the
 * `timedemo` cvar is set; the fps for each demo is reported from
 * CL_Disconnect when the demo stream ends, which is where the grid is
 * advanced (CL_SysReport_DemoFinished). The benchmark runs silent.
 *
 * =======================================================================
 */

#include "header/client.h"

#include <time.h>
#include <sys/stat.h>	// log-offset stat (all platforms)

#ifdef __APPLE__
#include <sys/sysctl.h>
#include <fcntl.h>
#include <unistd.h>
#endif

/* Q2's pak0 ships demo1.dm2 and demo2.dm2 only (no demo3, unlike Quake 1). */
#define SYSREPORT_NUM_DEMOS	2
#define SYSREPORT_NUM_RUNS	3
static const char * const sysreport_demos[SYSREPORT_NUM_DEMOS] = { "demo1", "demo2" };

static qboolean	sysreport_running = false;
static int	sysreport_demo;
static int	sysreport_run;
static int	sysreport_runs = SYSREPORT_NUM_RUNS;
static int	sysreport_ndemos = SYSREPORT_NUM_DEMOS;
static float	sysreport_fps[SYSREPORT_NUM_DEMOS][SYSREPORT_NUM_RUNS];

static float	sysreport_saved_svol;
static float	sysreport_saved_oggvol;
static long	sysreport_log_offset;	// qconsole.log size when the run began

// render/perf cvars the per-machine autoexec tunes -- "what produced these fps"
static const char * const sysreport_cvars[] = {
	"vid_fullscreen", "vid_desktopfullscreen", "gl_mode", "gl_customwidth", "gl_customheight",
	"gl_swapinterval", "cl_maxfps", "vid_maxfps",
	"gl_picmip", "gl_skymip", "gl_texturemode", "gl_anisotropic", "gl_msaa_samples", "gl_retexturing",
	"gl_dynamic", "gl_flashblend", "gl_shadows", "gl_stencilshadow", "gl_glows",
	"gl_trans_lighting", "gl_caustics", "gl_bloom", "gl_fog", "gl_waterwarp",
	"gl_groupdraw", "gl_decals", "gl_decal_max", "gl_finish", "gl_clear",
	"s_khz", "s_initsound",
};

static float
SR_MedianN(const float *v, int n)
{
	float a[SYSREPORT_NUM_RUNS];
	int i, j;

	if (n <= 0)
		return 0.0f;
	if (n > SYSREPORT_NUM_RUNS)
		n = SYSREPORT_NUM_RUNS;
	for (i = 0; i < n; i++)
		a[i] = v[i];
	for (i = 1; i < n; i++)
	{
		float k = a[i];
		j = i - 1;
		while (j >= 0 && a[j] > k) { a[j+1] = a[j]; j--; }
		a[j+1] = k;
	}
	if (n & 1)
		return a[n/2];
	return (a[n/2 - 1] + a[n/2]) * 0.5f;
}

static qboolean
SR_CopyFileRange(const char *src, const char *dst, long from)
{
	FILE *in, *out;
	char buf[8192];
	size_t n;

	in = fopen(src, "rb");
	if (!in)
		return false;
	out = fopen(dst, "wb");
	if (!out) { fclose(in); return false; }
	if (from > 0)
		fseek(in, from, SEEK_SET);
	while ((n = fread(buf, 1, sizeof(buf), in)) > 0)
		if (fwrite(buf, 1, n, out) != n)
			break;
	fclose(in);
	fclose(out);
	return true;
}

#ifdef __APPLE__
static void
SR_SysctlStr(const char *name, char *out, size_t outlen)
{
	size_t len = outlen;
	out[0] = '\0';
	if (sysctlbyname(name, out, &len, NULL, 0) != 0)
		out[0] = '\0';
	out[outlen - 1] = '\0';
}

static qboolean
SR_SysctlU64(const char *name, unsigned long long *v)
{
	uint64_t val = 0;
	size_t len = sizeof(val);
	if (sysctlbyname(name, &val, &len, NULL, 0) != 0)
		return false;
	*v = (unsigned long long)val;
	return true;
}

static qboolean
SR_SysctlInt(const char *name, int *v)
{
	int val = 0;
	size_t len = sizeof(val);
	if (sysctlbyname(name, &val, &len, NULL, 0) != 0)
		return false;
	*v = val;
	return true;
}

static void
SR_OSVersion(char *out, size_t outlen)
{
	FILE *f;
	char buf[8192];
	size_t n;
	const char *k, *p, *e;

	out[0] = '\0';
	f = fopen("/System/Library/CoreServices/SystemVersion.plist", "rb");
	if (!f)
		return;
	n = fread(buf, 1, sizeof(buf) - 1, f);
	fclose(f);
	buf[n] = '\0';

	k = strstr(buf, "ProductVersion");
	if (!k) return;
	p = strstr(k, "<string>");
	if (!p) return;
	p += 8;
	e = strstr(p, "</string>");
	if (!e) return;
	n = (size_t)(e - p);
	if (n >= outlen) n = outlen - 1;
	memcpy(out, p, n);
	out[n] = '\0';
}

static void
SR_RTrim(char *s)
{
	size_t n = strlen(s);
	while (n > 0 && (s[n-1]==' '||s[n-1]=='\t'||s[n-1]=='\r'||s[n-1]=='\n'))
		s[--n] = '\0';
}

static void
SR_GPUInfo(char *out, size_t outlen)
{
	FILE *p;
	char line[256];

	out[0] = '\0';
	p = popen("system_profiler SPDisplaysDataType 2>/dev/null", "r");
	if (!p) return;
	while (fgets(line, sizeof(line), p))
	{
		if (strstr(line, "VRAM") || strstr(line, "Chipset") || strstr(line, "Resolution"))
		{
			char *s = line, *nl;
			while (*s == ' ' || *s == '\t') s++;
			nl = strchr(s, '\n'); if (nl) *nl = '\0';
			if (out[0]) Q_strlcat(out, " | ", outlen);
			Q_strlcat(out, s, outlen);
		}
	}
	pclose(p);
}

static void
SR_StorageInfo(char *model_out, size_t model_len, char *medium_out, size_t medium_len)
{
	FILE *p;
	char line[256];

	model_out[0] = '\0';
	medium_out[0] = '\0';
	p = popen("system_profiler SPSerialATADataType SPParallelATADataType SPNVMeDataType 2>/dev/null", "r");
	if (!p) return;
	while (fgets(line, sizeof(line), p))
	{
		char *c, *nl;
		if (!model_out[0] && (c = strstr(line, "Model:")))
		{
			c += 6;
			while (*c == ' ' || *c == '\t') c++;
			nl = strchr(c, '\n'); if (nl) *nl = '\0';
			if (!strstr(c, "CD") && !strstr(c, "DVD") && !strstr(c, "RW") &&
			    !strstr(c, "Optical") && !strstr(c, "SuperDrive"))
			{
				Q_strlcpy(model_out, c, model_len);
				SR_RTrim(model_out);
			}
		}
		if (!medium_out[0] && (strstr(line, "Medium Type:") || strstr(line, "Solid State:")))
		{
			c = strchr(line, ':');
			if (c)
			{
				c++;
				while (*c == ' ' || *c == '\t') c++;
				nl = strchr(c, '\n'); if (nl) *nl = '\0';
				Q_strlcpy(medium_out, c, medium_len);
				SR_RTrim(medium_out);
			}
		}
	}
	pclose(p);
}

static void
SR_DiskBench(double *wmb, double *rmb, double *iops)
{
	enum { CHUNK = 1024 * 1024, NCHUNKS = 32, NRAND = 400 };
	char tmppath[MAX_OSPATH];
	char *buf;
	char small[4096];
	int fd, i, t0, t1;
	double totalmb = (double)NCHUNKS;

	*wmb = *rmb = *iops = 0.0;
	buf = (char *)malloc(CHUNK);
	if (!buf)
		return;
	memset(buf, 0xA5, CHUNK);

	Com_sprintf(tmppath, sizeof(tmppath), "%s/q2_diskbench.tmp", FS_Gamedir());

	fd = open(tmppath, O_WRONLY | O_CREAT | O_TRUNC, 0666);
	if (fd != -1)
	{
#ifdef F_NOCACHE
		fcntl(fd, F_NOCACHE, 1);
#endif
		t0 = Sys_Milliseconds();
		for (i = 0; i < NCHUNKS; i++)
			if (write(fd, buf, CHUNK) != (ssize_t)CHUNK)
				break;
		fsync(fd);
		t1 = Sys_Milliseconds();
		close(fd);
		if (t1 > t0)
			*wmb = totalmb / ((t1 - t0) / 1000.0);
	}

	fd = open(tmppath, O_RDONLY);
	if (fd != -1)
	{
#ifdef F_NOCACHE
		fcntl(fd, F_NOCACHE, 1);
#endif
		t0 = Sys_Milliseconds();
		while (read(fd, buf, CHUNK) > 0)
			;
		t1 = Sys_Milliseconds();
		if (t1 > t0)
			*rmb = totalmb / ((t1 - t0) / 1000.0);

		{
			off_t span = (off_t)NCHUNKS * CHUNK - sizeof(small);
			unsigned hash = 0;
			int ok = 0;

			t0 = Sys_Milliseconds();
			for (i = 0; i < NRAND; i++)
			{
				off_t off;
				hash += 2654435761u;
				off = (off_t)(hash % (unsigned)span) & ~((off_t)4095);
				if (lseek(fd, off, SEEK_SET) == (off_t)-1)
					break;
				if (read(fd, small, sizeof(small)) == (ssize_t)sizeof(small))
					ok++;
			}
			t1 = Sys_Milliseconds();
			if (t1 > t0 && ok > 0)
				*iops = ok / ((t1 - t0) / 1000.0);
		}
		close(fd);
	}

	remove(tmppath);
	free(buf);
}
#endif	/* __APPLE__ */

static const char *
SR_ArchLabel(void)
{
#if defined(__x86_64__) || defined(__amd64__)
	return "x86_64";
#elif defined(__VEC__) || defined(__ALTIVEC__)
	return "ppc-altivec";
#elif defined(__ppc__) || defined(__powerpc__) || defined(__POWERPC__)
	return "ppc";
#else
	return "unknown";
#endif
}

static void
CL_SysReport_Write(void)
{
	char path[MAX_OSPATH], logpath[MAX_OSPATH], logsrc[MAX_OSPATH];
	char model[128], cpubrand[160], osver[64], modelclean[128];
	char osrelease[64], gpuinfo[512], drivemodel[128], drivemedium[64];
	char res[32];
	unsigned long long memsize = 0, cpufreq = 0, busfreq = 0;
	int ncpu = 0, altivec = 0, l2cache = 0;
	double diskw = 0.0, diskr = 0.0, diskiops = 0.0;
	const char *glvendor, *glrenderer, *glversion;
	const char *home;
	time_t now;
	char tstamp[32];
	FILE *f;
	int i;
	size_t ci;

	glvendor = Cvar_VariableString("gl_vendor");
	glrenderer = Cvar_VariableString("gl_renderer");
	glversion = Cvar_VariableString("gl_version");
	if (!glvendor[0]) glvendor = "unknown";
	if (!glrenderer[0]) glrenderer = "unknown";
	if (!glversion[0]) glversion = "unknown";

	Q_strlcpy(model, "unknown", sizeof(model));
	cpubrand[0] = osver[0] = osrelease[0] = gpuinfo[0] = '\0';
	drivemodel[0] = drivemedium[0] = '\0';

#ifdef __APPLE__
	SR_SysctlStr("hw.model", model, sizeof(model));
	if (!model[0]) Q_strlcpy(model, "unknown", sizeof(model));
	SR_SysctlStr("machdep.cpu.brand_string", cpubrand, sizeof(cpubrand));
	SR_SysctlU64("hw.memsize", &memsize);
	SR_SysctlU64("hw.cpufrequency", &cpufreq);
	SR_SysctlU64("hw.busfrequency", &busfreq);
	SR_SysctlInt("hw.ncpu", &ncpu);
	SR_SysctlInt("hw.l2cachesize", &l2cache);
	SR_SysctlInt("hw.optional.altivec", &altivec);
	SR_SysctlStr("kern.osrelease", osrelease, sizeof(osrelease));
	SR_OSVersion(osver, sizeof(osver));
	SR_GPUInfo(gpuinfo, sizeof(gpuinfo));
	SR_StorageInfo(drivemodel, sizeof(drivemodel), drivemedium, sizeof(drivemedium));
	SR_DiskBench(&diskw, &diskr, &diskiops);
#endif
	if (!cpubrand[0]) Q_strlcpy(cpubrand, "n/a", sizeof(cpubrand));
	if (!osver[0]) Q_strlcpy(osver, "n/a", sizeof(osver));

	Q_strlcpy(modelclean, model, sizeof(modelclean));
	for (i = 0; modelclean[i]; i++)
	{
		char c = modelclean[i];
		if (c == ',' || c == ' ' || c == '/' || c == '\\')
			modelclean[i] = '-';
	}

	now = time(NULL);
	strftime(tstamp, sizeof(tstamp), "%Y-%m-%dT%H:%M:%SZ", gmtime(&now));
	Com_sprintf(res, sizeof(res), "%dx%d", (int)viddef.width, (int)viddef.height);

	home = getenv("HOME");
	if (home && home[0])
	{
		Com_sprintf(path,    sizeof(path),    "%s/Desktop/quake2-sysreport-%s.txt", home, modelclean);
		Com_sprintf(logpath, sizeof(logpath), "%s/Desktop/quake2-sysreport-%s.log", home, modelclean);
	}
	else
	{
		Com_sprintf(path,    sizeof(path),    "quake2-sysreport-%s.txt", modelclean);
		Com_sprintf(logpath, sizeof(logpath), "quake2-sysreport-%s.log", modelclean);
	}

	f = fopen(path, "w");
	if (!f)
	{
		Com_Printf("sysreport: FAILED to write %s\n", path);
		return;
	}

	fprintf(f, "Quake II sysreport\n");
	fprintf(f, "==================\n");
	fprintf(f, "engine     : Yamagi Quake II %s (%s)\n", VERSION, SR_ArchLabel());
	fprintf(f, "generated  : %s\n\n", tstamp);

	fprintf(f, "HARDWARE\n");
	fprintf(f, "  hw.model : %s\n", model);
	fprintf(f, "  cpu      : %s\n", cpubrand);
	fprintf(f, "  cpu cores: %d\n", ncpu);
	if (cpufreq) fprintf(f, "  cpu clock: %.0f MHz\n", cpufreq / 1000000.0);
	if (busfreq) fprintf(f, "  bus clock: %.0f MHz\n", busfreq / 1000000.0);
	if (l2cache) fprintf(f, "  l2 cache : %d KB\n", l2cache / 1024);
	if (memsize) fprintf(f, "  ram      : %.0f MB\n", memsize / (1024.0 * 1024.0));
	fprintf(f, "  altivec  : %s\n", altivec ? "yes" : "no");
	fprintf(f, "  os       : %s%s%s\n\n", osver, osrelease[0] ? " / Darwin " : "", osrelease);

	fprintf(f, "GRAPHICS\n");
	fprintf(f, "  GL_VENDOR  : %s\n", glvendor);
	fprintf(f, "  GL_RENDERER: %s\n", glrenderer);
	fprintf(f, "  GL_VERSION : %s\n", glversion);
	fprintf(f, "  bench res  : %s\n", res);
	if (gpuinfo[0]) fprintf(f, "  display    : %s\n", gpuinfo);
	fprintf(f, "\n");

	if (drivemodel[0] || drivemedium[0] || diskw > 0.0 || diskr > 0.0)
	{
		const char *est;
		if (drivemedium[0])
			est = drivemedium;
		else if (diskiops > 600.0)
			est = "likely SSD (high random-read IOPS)";
		else if (diskiops > 0.0)
			est = "likely spinning HDD (seek-bound IOPS)";
		else
			est = "unknown (see drive model)";

		fprintf(f, "STORAGE\n");
		if (drivemodel[0]) fprintf(f, "  drive    : %s\n", drivemodel);
		fprintf(f, "  type     : %s\n", est);
		if (diskw > 0.0) fprintf(f, "  seq write: %.1f MB/s\n", diskw);
		if (diskr > 0.0) fprintf(f, "  seq read : %.1f MB/s\n", diskr);
		if (diskiops > 0.0) fprintf(f, "  rand read: %.0f IOPS (4K)\n", diskiops);
		fprintf(f, "\n");
	}

	fprintf(f, "SETTINGS (cvar values during benchmark)\n");
	for (ci = 0; ci < sizeof(sysreport_cvars)/sizeof(sysreport_cvars[0]); ci++)
	{
		const char *val = Cvar_VariableString(sysreport_cvars[ci]);
		if (val && val[0])
			fprintf(f, "  %-24s %s\n", sysreport_cvars[ci], val);
	}
	fprintf(f, "\n");

	fprintf(f, "BENCHMARK (%d demos x %d runs, fps)\n", sysreport_ndemos, sysreport_runs);
	for (i = 0; i < sysreport_ndemos; i++)
	{
		int r;
		float med = SR_MedianN(sysreport_fps[i], sysreport_runs);
		fprintf(f, "  %-6s:", sysreport_demos[i]);
		for (r = 0; r < sysreport_runs; r++)
			fprintf(f, " %6.1f", sysreport_fps[i][r]);
		fprintf(f, "   median %6.1f\n", med);
	}

	fprintf(f, "\nCSV (paste into benchmarks/results.csv)\n");
	fprintf(f, "timestamp,commit,build_type,machine,cpu,gpu,os,demo,res,run1_fps,run2_fps,run3_fps,median_fps,notes\n");
	for (i = 0; i < sysreport_ndemos; i++)
	{
		int r;
		float med = SR_MedianN(sysreport_fps[i], sysreport_runs);
		fprintf(f, "%s,q2-%s,%s,\"%s\",\"%s\",\"%s\",\"%s\",%s,%s,",
			tstamp, VERSION, SR_ArchLabel(), model, cpubrand, glrenderer, osver,
			sysreport_demos[i], res);
		for (r = 0; r < SYSREPORT_NUM_RUNS; r++)
		{
			if (r < sysreport_runs)
				fprintf(f, "%.1f,", sysreport_fps[i][r]);
			else
				fprintf(f, "NA,");
		}
		fprintf(f, "%.2f,sysreport\n", med);
	}

	fclose(f);

	Com_Printf("\nsysreport: written to\n  %s\n", path);

	// copy the console log (this run's portion) next to the report
	Com_sprintf(logsrc, sizeof(logsrc), "%s/qconsole.log", FS_Gamedir());
	if (SR_CopyFileRange(logsrc, logpath, sysreport_log_offset))
		Com_Printf("sysreport: console log copied to\n  %s\n", logpath);

	Com_Printf("sysreport: email both files so your machine can be tuned. Thanks!\n");

#ifdef __APPLE__
	{
		char cmd[MAX_OSPATH + 16];
		Com_sprintf(cmd, sizeof(cmd), "open -R \"%s\" &", path);
		system(cmd);
	}
#endif
}

// restore engine state after a run (normal completion or abort)
static void
CL_SysReport_Finish(void)
{
	sysreport_running = false;
	Cvar_SetValue("timedemo", 0);
	Cvar_SetValue("s_volume", sysreport_saved_svol);
	Cvar_SetValue("ogg_volume", sysreport_saved_oggvol);
}

qboolean
CL_SysReport_Active(void)
{
	return sysreport_running;
}

/*
 * Called from CL_Disconnect when a timedemo demo finishes (that's where Q2
 * reports fps). Records the run and either queues the next demo or, when the
 * grid is complete, writes the report.
 */
void
CL_SysReport_DemoFinished(float fps)
{
	if (!sysreport_running)
		return;

	sysreport_fps[sysreport_demo][sysreport_run] = fps;
	Com_Printf("sysreport: %s run %d/%d = %.1f fps\n",
		sysreport_demos[sysreport_demo], sysreport_run + 1, sysreport_runs, fps);

	if (++sysreport_run >= sysreport_runs)
	{
		sysreport_run = 0;
		sysreport_demo++;
	}

	if (sysreport_demo >= sysreport_ndemos)
	{
		CL_SysReport_Write();
		CL_SysReport_Finish();
		return;
	}

	Cbuf_AddText(va("demomap %s.dm2\n", sysreport_demos[sysreport_demo]));
}

/*
 * sysreport [runs] [ndemos] -- collect specs + run the timedemo grid (silent)
 * and write the report to the Desktop. Defaults to the full 3x3 grid;
 * `sysreport 1 1` is a fast single-demo smoke test.
 */
void
CL_SysReport_f(void)
{
	char logsrc[MAX_OSPATH];
	struct stat st;

	if (sysreport_running)
	{
		Com_Printf("sysreport: already running\n");
		return;
	}

	sysreport_runs = SYSREPORT_NUM_RUNS;
	sysreport_ndemos = SYSREPORT_NUM_DEMOS;
	if (Cmd_Argc() >= 2)
		sysreport_runs = atoi(Cmd_Argv(1));
	if (Cmd_Argc() >= 3)
		sysreport_ndemos = atoi(Cmd_Argv(2));
	if (sysreport_runs < 1) sysreport_runs = 1;
	if (sysreport_runs > SYSREPORT_NUM_RUNS) sysreport_runs = SYSREPORT_NUM_RUNS;
	if (sysreport_ndemos < 1) sysreport_ndemos = 1;
	if (sysreport_ndemos > SYSREPORT_NUM_DEMOS) sysreport_ndemos = SYSREPORT_NUM_DEMOS;

	memset(sysreport_fps, 0, sizeof(sysreport_fps));
	sysreport_demo = 0;
	sysreport_run = 0;
	sysreport_running = true;

	// run silent: save + zero the audio volumes (restored in Finish)
	sysreport_saved_svol = Cvar_VariableValue("s_volume");
	sysreport_saved_oggvol = Cvar_VariableValue("ogg_volume");
	Cvar_SetValue("s_volume", 0);
	Cvar_SetValue("ogg_volume", 0);

	// ensure the console log is active + flushed, and note where this run
	// begins so the Desktop copy covers exactly the benchmark.
	Cvar_Set("logfile", "2");
	Com_sprintf(logsrc, sizeof(logsrc), "%s/qconsole.log", FS_Gamedir());
	sysreport_log_offset = 0;
	if (stat(logsrc, &st) == 0)
		sysreport_log_offset = (long)st.st_size;

	Com_Printf("sysreport: benchmarking %d demos x %d runs -- do not touch the controls...\n",
		sysreport_ndemos, sysreport_runs);

	Cvar_Set("timedemo", "1");
	Cbuf_AddText(va("demomap %s.dm2\n", sysreport_demos[0]));
}
