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
 * watchlink -- pushes the player's live in-game state out over UDP so an
 * external companion (an Apple Watch "tactical computer", or just `nc -ul`)
 * can render the marine's health / armor / ammo / inventory / objectives on
 * a second screen.
 *
 * Everything here is gated on the `watch_host` cvar: when it is empty the
 * feature is completely inert -- no sockets touched, no per-frame work, no
 * packets emitted -- so the default fleet build, the benchmarks and the DMG
 * behave exactly as before. This is a runtime-gated opt-in, NOT a load-time
 * change (see CLAUDE.md / MISTAKES.md on "zero-risk load-time" traps).
 *
 * Transport is newline-delimited JSON. The retro PPC fleet is big-endian, so
 * a hand-rolled binary struct would invite byte-order bugs; JSON via snprintf
 * is endianness-proof and debuggable with `nc -ul 27999`. Two heartbeat kinds
 * plus discrete events:
 *
 *   {"t":"vitals", ...}        ~watch_rate Hz, the status bar
 *   {"t":"meta", ...}          once per map load: level name + item-name table
 *   {"t":"event","kind":...}   damage / centerprint, as they happen
 *
 * The send path reuses the engine's existing UDP client socket via
 * NET_SendPacket; no new socket is opened. Sends are fire-and-forget on a
 * non-blocking socket, so an unreachable watch_host never stalls the frame.
 *
 * =======================================================================
 */

#include "header/client.h"

static cvar_t *watch_host;   /* "ip" or "ip:port"; empty => feature off */
static cvar_t *watch_port;   /* default port when watch_host omits one */
static cvar_t *watch_rate;   /* vitals heartbeat, Hz */
static cvar_t *watch_events; /* 1 => emit discrete damage/centerprint events */

static netadr_t watch_adr;       /* resolved destination */
static qboolean watch_adr_valid; /* did the last resolve succeed? */
static int watch_last_send;      /* cls.realtime of last vitals heartbeat */
static int watch_last_flashes;   /* STAT_FLASHES from the previous frame */

/*
 * Re-resolve watch_host into watch_adr. Accepts "ip" or "ip:port"; when no
 * port is given, watch_port is appended. Called lazily whenever the cvar
 * string changes so the user can retarget live from the console.
 */
static void
WatchLink_Resolve(void)
{
	char combined[128];

	watch_adr_valid = false;

	if (!watch_host || !watch_host->string[0])
	{
		return;
	}

	if (strchr(watch_host->string, ':'))
	{
		Q_strlcpy(combined, watch_host->string, sizeof(combined));
	}
	else
	{
		Com_sprintf(combined, sizeof(combined), "%s:%d",
				watch_host->string, (int)watch_port->value);
	}

	if (!NET_StringToAdr(combined, &watch_adr))
	{
		Com_Printf("watchlink: could not resolve watch_host '%s'\n", combined);
		return;
	}

	watch_adr_valid = true;
}

/*
 * True when the feature is armed and a destination is known. Picks up cvar
 * edits (host changed, or first use) without a restart.
 */
static qboolean
WatchLink_Ready(void)
{
	if (!watch_host || !watch_host->string[0])
	{
		return false;
	}

	if (watch_host->modified || !watch_adr_valid)
	{
		WatchLink_Resolve();
		watch_host->modified = false;
	}

	return watch_adr_valid;
}

static void
WatchLink_Send(const char *line)
{
	int len = (int)strlen(line);

	if (len <= 0)
	{
		return;
	}

	/* fire-and-forget; the client socket is non-blocking, and if it is not
	   yet open (disconnected) NET_SendPacket is a harmless no-op. */
	NET_SendPacket(NS_CLIENT, len, (void *)line, watch_adr);
}

/*
 * Copy src into dst with the characters JSON forbids bare (", \, control
 * chars, and Quake's high-bit "colored" text) escaped or stripped, so a
 * pickup/objective string can never break the line framing.
 */
static void
WatchLink_EscapeJson(char *dst, int dstsize, const char *src)
{
	int o = 0;

	for (; *src && o < dstsize - 7; src++)
	{
		unsigned char c = (unsigned char)*src;

		c &= 0x7f; /* drop Quake's high-bit colored glyphs */

		if (c == '"' || c == '\\')
		{
			dst[o++] = '\\';
			dst[o++] = c;
		}
		else if (c == '\n')
		{
			dst[o++] = '\\';
			dst[o++] = 'n';
		}
		else if (c >= ' ')
		{
			dst[o++] = c;
		}
		/* other control chars dropped */
	}

	dst[o] = 0;
}

/*
 * Resolve a configstring slot to its (escaped) string, or "" if empty/out of
 * range. Used for item names (CS_ITEMS) and powerup icons (CS_IMAGES).
 */
static void
WatchLink_ConfigName(char *dst, int dstsize, int cs_index)
{
	if (cs_index <= 0 || cs_index >= MAX_CONFIGSTRINGS)
	{
		dst[0] = 0;
		return;
	}

	WatchLink_EscapeJson(dst, dstsize, cl.configstrings[cs_index]);
}

void
CL_WatchLink_Init(void)
{
	watch_host = Cvar_Get("watch_host", "", CVAR_ARCHIVE);
	watch_port = Cvar_Get("watch_port", "27999", CVAR_ARCHIVE);
	watch_rate = Cvar_Get("watch_rate", "10", CVAR_ARCHIVE);
	watch_events = Cvar_Get("watch_events", "1", CVAR_ARCHIVE);

	watch_adr_valid = false;
	watch_last_send = 0;
	watch_last_flashes = 0;
}

/*
 * Emit a one-off event line. kind is the event class ("damage",
 * "centerprint", ...); detail is pre-formatted JSON members (already escaped)
 * appended verbatim, e.g. ,"msg":"You got the Railgun".
 */
void
CL_WatchLink_Event(const char *kind, const char *detail)
{
	char line[1280];

	/* WatchLink_Ready() null-checks the cvars; only deref watch_events after
	   it passes (a non-empty watch_host guarantees Init ran). */
	if (!WatchLink_Ready() || !watch_events->value)
	{
		return;
	}

	Com_sprintf(line, sizeof(line),
			"{\"t\":\"event\",\"kind\":\"%s\"%s}\n",
			kind, detail ? detail : "");
	WatchLink_Send(line);
}

/*
 * Hooked from SCR_CenterPrint: forward story / pickup / objective text.
 */
void
CL_WatchLink_CenterPrint(const char *str)
{
	char esc[1024];
	char detail[1100];

	if (!WatchLink_Ready() || !watch_events->value)
	{
		return;
	}

	WatchLink_EscapeJson(esc, sizeof(esc), str);
	Com_sprintf(detail, sizeof(detail), ",\"msg\":\"%s\"", esc);
	CL_WatchLink_Event("centerprint", detail);
}

/*
 * Hooked at map load (precache complete): send the static lookup tables the
 * watch needs to turn indices into names -- level name plus the owned-item
 * names. Sent once, not per frame.
 */
void
CL_WatchLink_Meta(void)
{
	/* sized to stay under a single ~1500-byte Ethernet MTU so the meta
	   datagram is never IP-fragmented on the retro Wi-Fi links. */
	char line[1400];
	char name[128];
	int i, n, off;

	if (!WatchLink_Ready())
	{
		return;
	}

	WatchLink_ConfigName(name, sizeof(name), CS_NAME);
	Com_sprintf(line, sizeof(line),
			"{\"t\":\"meta\",\"level\":\"%s\",\"items\":[", name);
	off = (int)strlen(line);

	/* item names for slots the player can actually own; stop before we
	   would overflow the (sub-MTU) line buffer, reserving room for "]}\n". */
	n = 0;

	for (i = 0; i < MAX_ITEMS; i++)
	{
		WatchLink_ConfigName(name, sizeof(name), CS_ITEMS + i);

		if (!name[0])
		{
			continue;
		}

		/* worst case appended: ,"<name>" plus the closing "]}\n\0" */
		if (off + (int)strlen(name) + 8 >= (int)sizeof(line))
		{
			break;
		}

		Com_sprintf(line + off, sizeof(line) - off,
				n ? ",\"%s\"" : "\"%s\"", name);
		off += (int)strlen(line + off); /* advance past the new fragment only */
		n++;
	}

	Q_strlcat(line, "]}\n", sizeof(line));
	WatchLink_Send(line);
}

/*
 * Per-frame heartbeat. Called from the tail of CL_Frame. Throttled to
 * watch_rate Hz; also raises a "damage" event on the STAT_FLASHES rising
 * edge so the watch can buzz the wrist the instant the marine is hit.
 */
void
CL_WatchLink_Frame(void)
{
	const short *st;
	char line[1024];
	char sel[128];
	char pic[128];
	int interval, flashes;

	if (!WatchLink_Ready())
	{
		return;
	}

	/* only meaningful once we are actually in a level */
	if (cls.state != ca_active || !cl.frame.valid)
	{
		watch_last_flashes = 0;
		return;
	}

	st = cl.frame.playerstate.stats;

	/* damage edge -> immediate event (which subsystems were hit) */
	flashes = st[STAT_FLASHES];

	if (watch_events->value && (flashes & ~watch_last_flashes))
	{
		char detail[64];
		Com_sprintf(detail, sizeof(detail),
				",\"health\":%d,\"armor\":%d,\"ammo\":%d",
				(flashes & 1) ? 1 : 0,
				(flashes & 2) ? 1 : 0,
				(flashes & 4) ? 1 : 0);
		CL_WatchLink_Event("damage", detail);
	}

	watch_last_flashes = flashes;

	/* throttle the vitals heartbeat; floor at 1ms so a large watch_rate
	   can't truncate the interval to 0 and emit on every single frame. */
	interval = (watch_rate->value > 0) ? (int)(1000.0f / watch_rate->value) : 100;

	if (interval < 1)
	{
		interval = 1;
	}

	if (cls.realtime - watch_last_send < interval)
	{
		return;
	}

	watch_last_send = cls.realtime;

	/* STAT_SELECTED_ITEM is a server-supplied short; clamp to a real item
	   slot so a bogus value can't read an unrelated configstring block. */
	WatchLink_ConfigName(sel, sizeof(sel),
			(st[STAT_SELECTED_ITEM] >= 0 && st[STAT_SELECTED_ITEM] < MAX_ITEMS)
				? (CS_ITEMS + st[STAT_SELECTED_ITEM]) : 0);
	WatchLink_ConfigName(pic, sizeof(pic),
			st[STAT_TIMER_ICON] ? (CS_IMAGES + st[STAT_TIMER_ICON]) : 0);

	Com_sprintf(line, sizeof(line),
			"{\"t\":\"vitals\","
			"\"hp\":%d,\"armor\":%d,\"ammo\":%d,"
			"\"sel\":\"%s\","
			"\"frags\":%d,\"flashes\":%d,\"layouts\":%d,\"spec\":%d,"
			"\"pu\":{\"icon\":\"%s\",\"sec\":%d}}\n",
			st[STAT_HEALTH], st[STAT_ARMOR], st[STAT_AMMO],
			sel,
			st[STAT_FRAGS], flashes, st[STAT_LAYOUTS], st[STAT_SPECTATOR],
			pic, st[STAT_TIMER]);

	WatchLink_Send(line);
}
