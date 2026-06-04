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

/*
 * Zero-config discovery (macOS only). When watch_host is the literal "auto"
 * we browse Bonjour for the companion's "_q2watch._udp" service instead of
 * resolving a typed IP, so the phone never has to be addressed by hand. This
 * is libSystem/mDNSResponder, present on every Mac the fleet targets (Panther
 * 10.3 .. Leopard 10.5 .. Lion), and is compiled out everywhere else.
 *
 * The browse/resolve calls ship on all four fleet OSes, but the SDK *headers*
 * drifted across versions, so we paper over the gaps to keep ONE source file
 * compiling — and auto-discovering — for every slice (g3 10.3.9, g4 10.4u,
 * g5 10.5, lion):
 *   - DNSSD_API (a calling-convention macro) and kDNSServiceInterfaceIndexAny
 *     first appear in the 10.4u SDK; the 10.3.9 headers lack both. We supply
 *     a no-op / zero fallback there. (For the constant we gate on the SDK
 *     version rather than #ifndef: on 10.4u+ it's an enum, not a macro, so a
 *     blind #define would corrupt the enum declaration.)
 *   - DNSServiceGetAddrInfo (explicit A-record lookup) is 10.5+. On 10.3/10.4
 *     we fall back to handing the resolver's hosttarget to NET_StringToAdr.
 *   - The DNSServiceResolveReply txtRecord arg is `const char *` through 10.4u
 *     and `const unsigned char *` from 10.5 on; we match each exactly so our
 *     callback's type is identical to the SDK typedef (no incompatible-pointer
 *     warning, no implicit-decl cascade).
 */
#ifdef __APPLE__
#include <AvailabilityMacros.h>
#include <dns_sd.h>
#include <arpa/inet.h>
#include <sys/select.h>
#define WATCHLINK_BONJOUR 1

#if defined(MAC_OS_X_VERSION_MAX_ALLOWED) && MAC_OS_X_VERSION_MAX_ALLOWED < 1040
#ifndef DNSSD_API
#define DNSSD_API
#endif
#define kDNSServiceInterfaceIndexAny 0
#endif

#if defined(MAC_OS_X_VERSION_MAX_ALLOWED) && MAC_OS_X_VERSION_MAX_ALLOWED >= 1050
#define WATCHLINK_HAVE_ADDRINFO 1
#define WATCHLINK_TXTREC const unsigned char
#else
#define WATCHLINK_TXTREC const char
#endif
#endif /* __APPLE__ */

/*
 * Watchlink owns a dedicated UDP socket for OUTBOUND sends rather than reusing
 * the engine's client socket. In a single-player game the client talks to the
 * local server over loopback (the netchan shows 0.0.0.0:0), so the engine's
 * UDP client socket is never usable for a real LAN destination and every
 * NET_SendPacket is a silent no-op -- the companion gets zero packets. A
 * private non-blocking UDP socket sidesteps the engine's whole net-config /
 * connection state. POSIX everywhere the fleet runs; Windows falls back to
 * NET_SendPacket (untested there, not a fleet target for this feature).
 */
#ifndef _WIN32
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#define WATCHLINK_OWNSOCK 1
#endif

static cvar_t *watch_host;   /* "ip"/"ip:port", "auto" for Bonjour, "" => off */
static cvar_t *watch_port;   /* default port when watch_host omits one */
static cvar_t *watch_rate;   /* vitals heartbeat, Hz */
static cvar_t *watch_events; /* 1 => emit discrete damage/centerprint events */

static netadr_t watch_adr;       /* resolved destination */
static qboolean watch_adr_valid; /* did the last resolve succeed? */
static int watch_last_send;      /* cls.realtime of last vitals heartbeat */
static int watch_last_flashes;   /* STAT_FLASHES from the previous frame */
static char watch_last_vitals[1024]; /* last vitals payload sent (change-detect) */
static qboolean watch_meta_pending; /* meta table queued; send once adr resolves */
static char watch_last_inv[1100];    /* last inventory payload sent (change-detect) */
static int watch_last_inv_send;      /* cls.realtime of last inventory send (rate cap) */
static char watch_last_cp[1024];     /* last centerprint forwarded (dedup re-fires) */

#ifdef WATCHLINK_OWNSOCK
static int watch_sock = -1;          /* our own outbound UDP socket */
static struct sockaddr_in watch_sin; /* resolved companion destination */
static qboolean watch_sin_valid;     /* watch_sin populated? */
static int watch_sent_count;         /* packets sent since last (re)connect */
#endif

#ifdef WATCHLINK_BONJOUR
/* Three-stage async lookup: browse -> resolve instance -> get IPv4 address.
   Each DNSServiceRef carries a socket we poll (non-blocking) from the frame. */
static DNSServiceRef watch_browse_ref;   /* browsing for the service type */
static DNSServiceRef watch_resolve_ref;  /* resolving a found instance */
static qboolean watch_discovering;       /* a browse is currently armed */
static uint16_t watch_disc_port;         /* service port (network byte order) */
static int watch_disc_until;             /* cls.realtime deadline to give up a fruitless browse */

/* How long to keep browsing before giving up, to spare CPU when no companion
   is on the LAN. Re-armed at launch and at the start of every new game/map. */
#define WATCHLINK_DISCOVERY_MS 30000
#ifdef WATCHLINK_HAVE_ADDRINFO
static DNSServiceRef watch_addr_ref;     /* IPv4 address of the host (10.5+) */
#endif
#endif

static qboolean WatchLink_IsAuto(void);
static void WatchLink_Sync(void);

#ifdef WATCHLINK_OWNSOCK
/* Parse "a.b.c.d:port" (numeric IPv4) into watch_sin. A non-numeric host leaves
   watch_sin invalid, and WatchLink_Send falls back to the engine path. */
static void
WatchLink_SetSin(const char *hostport)
{
	char buf[80];
	char *colon;
	int port;

	watch_sin_valid = false;
	Q_strlcpy(buf, hostport, sizeof(buf));
	colon = strrchr(buf, ':');
	if (!colon)
	{
		return;
	}
	*colon = '\0';
	port = atoi(colon + 1);
	if (port <= 0 || port > 65535)
	{
		return;
	}

	memset(&watch_sin, 0, sizeof(watch_sin));
	watch_sin.sin_family = AF_INET;
	watch_sin.sin_port = htons((unsigned short)port);
	if (inet_pton(AF_INET, buf, &watch_sin.sin_addr) == 1)
	{
		watch_sin_valid = true;
	}
}
#endif

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
#ifdef WATCHLINK_OWNSOCK
	WatchLink_SetSin(combined); /* numeric IP -> our own socket destination */
#endif
}

/* True when watch_host requests Bonjour auto-discovery rather than a typed IP. */
static qboolean
WatchLink_IsAuto(void)
{
	return watch_host && !Q_stricmp(watch_host->string, "auto");
}

#ifdef WATCHLINK_BONJOUR
/* Set watch_adr from a "host:port" string (numeric IP, or a name getaddrinfo
   can resolve). Shared by the 10.5+ address reply and the pre-10.5 fallback. */
static void
WatchLink_SetTarget(const char *hostport)
{
	netadr_t a;

	if (NET_StringToAdr((char *)hostport, &a))
	{
		watch_adr = a;
		if (!watch_adr_valid)
		{
			Com_Printf("watchlink: discovered companion at %s\n", hostport);
		}
		watch_adr_valid = true;
#ifdef WATCHLINK_OWNSOCK
		WatchLink_SetSin(hostport); /* numeric IP -> our own socket destination */
#endif
	}
}

static void
WatchLink_StopDiscovery(void)
{
#ifdef WATCHLINK_HAVE_ADDRINFO
	if (watch_addr_ref) { DNSServiceRefDeallocate(watch_addr_ref); watch_addr_ref = NULL; }
#endif
	if (watch_resolve_ref) { DNSServiceRefDeallocate(watch_resolve_ref); watch_resolve_ref = NULL; }
	if (watch_browse_ref) { DNSServiceRefDeallocate(watch_browse_ref); watch_browse_ref = NULL; }
	watch_discovering = false;
}

#ifdef WATCHLINK_HAVE_ADDRINFO
/* Stage 3 (10.5+): the host's IPv4 address arrived -> build the destination. */
static void DNSSD_API
WatchLink_AddrReply(DNSServiceRef sdRef, DNSServiceFlags flags,
		uint32_t interfaceIndex, DNSServiceErrorType err,
		const char *hostname, const struct sockaddr *address,
		uint32_t ttl, void *context)
{
	const struct sockaddr_in *sin;
	char ip[64];
	char hostport[80];

	(void)sdRef; (void)flags; (void)interfaceIndex; (void)hostname;
	(void)ttl; (void)context;

	if (err != kDNSServiceErr_NoError || !address ||
			address->sa_family != AF_INET)
	{
		return;
	}

	sin = (const struct sockaddr_in *)address;
	if (!inet_ntop(AF_INET, &sin->sin_addr, ip, sizeof(ip)))
	{
		return;
	}

	/* numeric IP + the port advertised by the service -> netadr (no DNS) */
	Com_sprintf(hostport, sizeof(hostport), "%s:%u",
			ip, (unsigned)ntohs(watch_disc_port));
	WatchLink_SetTarget(hostport);
}
#endif /* WATCHLINK_HAVE_ADDRINFO */

/* Stage 2: a service instance resolved to host:port. On 10.5+ we then resolve
   its IPv4 address explicitly; on older SDKs we hand the hosttarget straight
   to NET_StringToAdr (getaddrinfo). */
static void DNSSD_API
WatchLink_ResolveReply(DNSServiceRef sdRef, DNSServiceFlags flags,
		uint32_t interfaceIndex, DNSServiceErrorType err,
		const char *fullname, const char *hosttarget, uint16_t port,
		uint16_t txtLen, WATCHLINK_TXTREC *txtRecord, void *context)
{
	(void)sdRef; (void)flags; (void)fullname;
	(void)txtLen; (void)txtRecord; (void)context;

	if (err != kDNSServiceErr_NoError)
	{
		return;
	}

	watch_disc_port = port; /* network byte order */

#ifdef WATCHLINK_HAVE_ADDRINFO
	if (watch_addr_ref)
	{
		DNSServiceRefDeallocate(watch_addr_ref);
		watch_addr_ref = NULL;
	}
	DNSServiceGetAddrInfo(&watch_addr_ref, 0, interfaceIndex,
			kDNSServiceProtocol_IPv4, hosttarget,
			WatchLink_AddrReply, NULL);
#else
	{
		char hostport[80];
		(void)interfaceIndex;
		Com_sprintf(hostport, sizeof(hostport), "%s:%u",
				hosttarget, (unsigned)ntohs(port));
		WatchLink_SetTarget(hostport);
	}
#endif
}

/* Stage 1: a companion appeared on the LAN -> resolve it. */
static void DNSSD_API
WatchLink_BrowseReply(DNSServiceRef sdRef, DNSServiceFlags flags,
		uint32_t interfaceIndex, DNSServiceErrorType err,
		const char *serviceName, const char *regtype,
		const char *replyDomain, void *context)
{
	(void)sdRef; (void)context;

	if (err != kDNSServiceErr_NoError || !(flags & kDNSServiceFlagsAdd))
	{
		return; /* ignore errors and "service went away" notifications */
	}

	if (watch_resolve_ref)
	{
		DNSServiceRefDeallocate(watch_resolve_ref);
		watch_resolve_ref = NULL;
	}
	DNSServiceResolve(&watch_resolve_ref, 0, interfaceIndex,
			serviceName, regtype, replyDomain,
			WatchLink_ResolveReply, NULL);
}

static void
WatchLink_StartDiscovery(void)
{
	DNSServiceErrorType err;

	WatchLink_StopDiscovery();

	err = DNSServiceBrowse(&watch_browse_ref, 0, kDNSServiceInterfaceIndexAny,
			"_q2watch._udp", NULL, WatchLink_BrowseReply, NULL);

	if (err != kDNSServiceErr_NoError)
	{
		Com_Printf("watchlink: Bonjour browse failed (err %d); "
				"set watch_host to an IP instead\n", (int)err);
		watch_browse_ref = NULL;
		return;
	}

	watch_discovering = true;
	watch_disc_until = cls.realtime + WATCHLINK_DISCOVERY_MS;
	Com_Printf("watchlink: browsing for companion (_q2watch._udp)...\n");
}

/* Service any ready DNS-SD socket, without blocking the frame. */
static void
WatchLink_PumpRef(DNSServiceRef ref)
{
	int fd;
	fd_set set;
	struct timeval tv;

	if (!ref)
	{
		return;
	}

	fd = DNSServiceRefSockFD(ref);
	if (fd < 0)
	{
		return;
	}

	FD_ZERO(&set);
	FD_SET(fd, &set);
	tv.tv_sec = 0;
	tv.tv_usec = 0;

	if (select(fd + 1, &set, NULL, NULL, &tv) > 0 && FD_ISSET(fd, &set))
	{
		DNSServiceProcessResult(ref);
	}
}

static void
WatchLink_PumpDiscovery(void)
{
	/* Read globals fresh between pumps: a browse reply may (re)arm the resolve
	   ref, and a resolve reply may (re)arm the addr ref, within these calls. */
	WatchLink_PumpRef(watch_browse_ref);
	WatchLink_PumpRef(watch_resolve_ref);
#ifdef WATCHLINK_HAVE_ADDRINFO
	WatchLink_PumpRef(watch_addr_ref);
#endif
}
#endif /* WATCHLINK_BONJOUR */

/*
 * Bring internal state in line with the watch_host cvar and, in "auto" mode,
 * drive Bonjour discovery. Cheap to call every frame; only does real work when
 * the cvar changed or a discovery socket has data pending.
 */
static void
WatchLink_Sync(void)
{
	if (!watch_host)
	{
		return;
	}

	if (watch_host->modified)
	{
		watch_host->modified = false;
		watch_adr_valid = false;
#ifdef WATCHLINK_BONJOUR
		WatchLink_StopDiscovery();
#endif
		if (watch_host->string[0] && WatchLink_IsAuto())
		{
#ifdef WATCHLINK_BONJOUR
			WatchLink_StartDiscovery();
#else
			Com_Printf("watchlink: \"auto\" needs macOS Bonjour; "
					"set watch_host to an IP instead\n");
#endif
		}
	}

#ifdef WATCHLINK_BONJOUR
	if (watch_discovering)
	{
		WatchLink_PumpDiscovery();

		/* Stop browsing once we have a destination, or after the window
		   elapses with no companion found -- so a phoneless game pays nothing
		   per frame. Discovery re-arms on the next new game / map load. */
		if (watch_adr_valid)
		{
			WatchLink_StopDiscovery();
		}
		else if (cls.realtime > watch_disc_until)
		{
			WatchLink_StopDiscovery();
			Com_Printf("watchlink: no companion found; idling "
					"(starts a new game to retry)\n");
		}
	}
#endif
}

/*
 * True when the feature is armed and a destination is known. Picks up cvar
 * edits (host changed, or first use) without a restart. In "auto" mode the
 * address is supplied asynchronously by Bonjour discovery (WatchLink_Sync);
 * a typed IP is resolved here lazily.
 */
static qboolean
WatchLink_Ready(void)
{
	/* A timedemo benchmark is running: stay COMPLETELY inert so the feed never
	   perturbs the FPS measurement. The fleet cfg sets watch_host "auto", so a
	   benchmark on a fleet box would otherwise stream vitals/inventory/damage
	   every frame. Bailing before WatchLink_Sync() also stops Bonjour discovery
	   pumping during the run. Covers `timedemo` and the `sysreport` grid (which
	   sets the same cvar). Returns to normal the instant the benchmark ends. */
	if (cl_timedemo && cl_timedemo->value)
	{
		return false;
	}

	WatchLink_Sync();

	if (!watch_host || !watch_host->string[0])
	{
		return false;
	}

	if (!watch_adr_valid && !WatchLink_IsAuto())
	{
		WatchLink_Resolve();
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

#ifdef WATCHLINK_OWNSOCK
	/* Send via our OWN non-blocking UDP socket so it works in single-player
	   (where the engine's client socket is loopback-only / unusable). */
	if (watch_sin_valid)
	{
		if (watch_sock < 0)
		{
			watch_sock = socket(AF_INET, SOCK_DGRAM, 0);
			if (watch_sock >= 0)
			{
				fcntl(watch_sock, F_SETFL, O_NONBLOCK);
			}
		}
		if (watch_sock >= 0)
		{
			sendto(watch_sock, line, (size_t)len, 0,
					(struct sockaddr *)&watch_sin, sizeof(watch_sin));
			if (watch_sent_count++ == 0)
			{
				Com_Printf("watchlink: streaming to %s:%u\n",
						inet_ntoa(watch_sin.sin_addr),
						(unsigned)ntohs(watch_sin.sin_port));
			}
			return;
		}
	}
#endif
	/* Fallback (Windows, or non-numeric host): reuse the engine client socket.
	   Harmless no-op if that socket is not open. */
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
	watch_last_vitals[0] = '\0';
	watch_last_inv[0] = '\0';
	watch_last_inv_send = 0;
	watch_last_cp[0] = '\0';

	/* Force a one-time reconcile on the first frame so an archived
	   watch_host (incl. "auto") is honoured without needing a console edit. */
	watch_host->modified = true;
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

	/* Never forward the menu attract-loop demo's center-prints (e.g. base1's
	   "crouch here") -- they'd show up on the companion before the player has
	   even started. Mirrors the guard in Sound/Frame/Layout/Meta. */
	if (!WatchLink_Ready() || !watch_events->value || cl.attractloop)
	{
		return;
	}

	/* Drop consecutive duplicate centerprints (a re-firing trigger you're
	   standing in) so the companion's comms log isn't spammed. Reset per map. */
	if (!strcmp(str, watch_last_cp))
	{
		return;
	}
	Q_strlcpy(watch_last_cp, str, sizeof(watch_last_cp));

	WatchLink_EscapeJson(esc, sizeof(esc), str);
	Com_sprintf(detail, sizeof(detail), ",\"msg\":\"%s\"", esc);
	CL_WatchLink_Event("centerprint", detail);
}

/*
 * Hooked from CL_ParseStartSoundPacket: forward the LOCAL player's vocal sounds
 * (*jump/pain/death/fall/gurp/...) and item/pickup/powerup sounds so the
 * companion can play the real Quake II effect. Weapon fire, footsteps and world
 * ambience are skipped. `cfgname` is the CS_SOUNDS configstring, e.g.
 * "*jump1.wav", "items/s_health.wav", "misc/w_pkup.wav" -> we forward the bare
 * basename ("jump1", "s_health", "w_pkup") as the event msg.
 */
void
CL_WatchLink_Sound(const char *cfgname)
{
	const char *p;
	const char *slash;
	char base[64];
	char esc[80];
	char detail[100];
	size_t n;

	if (cl.attractloop)
	{
		return; /* don't echo the menu demo's sounds to the companion */
	}

	if (!cfgname || !cfgname[0])
	{
		return;
	}

	if (cfgname[0] == '*')
	{
		p = cfgname + 1;                 /* player model vocal */
	}
	else if (!strncmp(cfgname, "items/", 6))
	{
		p = cfgname + 6;                 /* pickups / powerups */
	}
	else if (!strncmp(cfgname, "misc/", 5) &&
			(strstr(cfgname, "pkup") || strstr(cfgname, "pc_up")))
	{
		p = cfgname + 5;                 /* pickups + the "computer updated" beep */
	}
	else
	{
		return;                          /* not a player-feedback sound */
	}

	slash = strrchr(p, '/');
	if (slash)
	{
		p = slash + 1;
	}

	Q_strlcpy(base, p, sizeof(base));
	n = strlen(base);
	if (n > 4 && !Q_stricmp(base + n - 4, ".wav"))
	{
		base[n - 4] = '\0';
	}
	if (!base[0])
	{
		return;
	}

	WatchLink_EscapeJson(esc, sizeof(esc), base);
	Com_sprintf(detail, sizeof(detail), ",\"msg\":\"%s\"", esc);
	CL_WatchLink_Event("psound", detail);
}

/*
 * Hooked from svc_layout. The F1 "help computer" arrives as a layout-DSL string
 * whose human-readable content is exactly the quoted "..." arguments. The game's
 * HelpComputerMessage() emits them in a FIXED order:
 *   [0] skill   [1] level name   [2] objective 1   [3] objective 2
 *   [4] column header   [5] "kills  goals  secrets" counts line.
 * We pull those out and forward STRUCTURED fields so the companion can lay them
 * out cleanly (label vs value), instead of a positional blob the client has to
 * re-parse. The deathmatch scoreboard ALSO comes through svc_layout, so we only
 * act on the help computer (its layout always contains "picn help"). Deduped:
 * only re-sent when the layout actually changes (e.g. as the counts tick up).
 */
void
CL_WatchLink_Layout(const char *layout)
{
	static char last[1024];
	char fields[6][160];
	char esc[4][200];
	char detail[1100];
	char kills[24], goals[24], secrets[24];
	int nf = 0, i, o = 0, inq = 0;
	int k, kt, g, gt, s, st2;

	if (cl.attractloop)
	{
		return; /* menu attract-loop demo, not a human session */
	}
	if (!layout || !layout[0])
	{
		return;
	}
	/* Only the F1 help computer carries mission text; ignore the scoreboard. */
	if (!strstr(layout, "picn help"))
	{
		return;
	}
	if (!strcmp(layout, last))
	{
		return; /* unchanged */
	}
	Q_strlcpy(last, layout, sizeof(last));

	/* pull the quoted arguments, in order, into fields[] */
	for (i = 0; layout[i] && nf < 6; i++)
	{
		char c = layout[i];
		if (c == '"')
		{
			if (!inq)
			{
				inq = 1;
				o = 0;
			}
			else
			{
				inq = 0;
				fields[nf][o] = '\0';
				nf++;
			}
			continue;
		}
		if (inq && o < (int)sizeof(fields[0]) - 1)
		{
			fields[nf][o++] = c;
		}
	}
	for (i = nf; i < 6; i++)
	{
		fields[i][0] = '\0';
	}

	/* counts line -> three "found/total" pairs (blank if it didn't parse) */
	kills[0] = goals[0] = secrets[0] = '\0';
	if (sscanf(fields[5], " %d/%d %d/%d %d/%d",
				&k, &kt, &g, &gt, &s, &st2) == 6)
	{
		Com_sprintf(kills, sizeof(kills), "%d/%d", k, kt);
		Com_sprintf(goals, sizeof(goals), "%d/%d", g, gt);
		Com_sprintf(secrets, sizeof(secrets), "%d/%d", s, st2);
	}

	for (i = 0; i < 4; i++)
	{
		WatchLink_EscapeJson(esc[i], sizeof(esc[i]), fields[i]);
	}

	Com_sprintf(detail, sizeof(detail),
			",\"skill\":\"%s\",\"loc\":\"%s\",\"obj1\":\"%s\",\"obj2\":\"%s\""
			",\"kills\":\"%s\",\"goals\":\"%s\",\"secrets\":\"%s\"",
			esc[0], esc[1], esc[2], esc[3], kills, goals, secrets);
	CL_WatchLink_Event("objectives", detail);
}

/*
 * New game / level load: re-arm discovery so the link freshens for this session
 * -- handles the phone having reconnected, slept, or changed address between
 * games -- WITHOUT dropping the current target, so the meta below still goes out
 * immediately to the last-known address. Also resets the per-session edge state
 * so the first frame of the new map emits a clean vitals heartbeat at once.
 */
static void
WatchLink_Reconnect(void)
{
	watch_last_flashes = 0;
	watch_last_send = 0;
	watch_last_vitals[0] = '\0';
	watch_last_cp[0] = '\0';       /* re-allow this map's centerprints */
	watch_last_inv[0] = '\0';      /* force a fresh inventory push this session */
	watch_last_inv_send = 0;
#ifdef WATCHLINK_OWNSOCK
	watch_sent_count = 0; /* re-announce the stream target once per session */
#endif

#ifdef WATCHLINK_BONJOUR
	if (WatchLink_IsAuto())
	{
		WatchLink_StartDiscovery(); /* re-browse; refreshes watch_adr when it lands */
		return;
	}
#endif
	WatchLink_Resolve(); /* re-resolve a literal host */
}

/*
 * Build and send the static lookup tables the watch needs to turn indices into
 * names -- level name plus the owned-item names. Caller guarantees we have a
 * resolved destination (watch_adr_valid).
 */
static void
WatchLink_SendMeta(void)
{
	/* sized to stay under a single ~1500-byte Ethernet MTU so the meta
	   datagram is never IP-fragmented on the retro Wi-Fi links. */
	char line[1400];
	char name[128];
	char raw[128];
	const char *world, *slash;
	char *dot;
	int i, n, off;

	WatchLink_ConfigName(name, sizeof(name), CS_NAME);

	/* Maps without a worldspawn "message" leave CS_NAME empty, so SECTOR would
	   show a blank. Fall back to the world model's basename, which is always
	   present: "maps/base1.bsp" -> "base1". */
	if (!name[0])
	{
		world = cl.configstrings[CS_MODELS + 1];
		slash = strrchr(world, '/');
		Q_strlcpy(raw, slash ? slash + 1 : world, sizeof(raw));
		dot = strrchr(raw, '.');
		if (dot)
		{
			*dot = '\0';
		}
		WatchLink_EscapeJson(name, sizeof(name), raw);
	}

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
 * Hooked at map load (precache complete). Re-arm discovery for the new session
 * and queue the meta table; it is actually sent from the frame loop as soon as
 * we have a resolved destination -- in "auto" mode Bonjour discovery usually
 * has NOT completed at map-load time, so requiring a live address here would
 * silently drop the most important map's level/item table.
 */
void
CL_WatchLink_Meta(void)
{
	if (!watch_host || !watch_host->string[0])
	{
		return; /* feature off -- stay fully inert */
	}

	if (cl.attractloop)
	{
		return; /* menu attract-loop demo, not a human session */
	}

	if (cl_timedemo && cl_timedemo->value)
	{
		return; /* benchmark in progress -- don't re-arm discovery or send meta */
	}

	WatchLink_Reconnect();      /* re-arm discovery + reset per-session edges */
	watch_meta_pending = true;  /* frame loop sends it once watch_adr_valid */

	/* If a destination is already known (literal IP, or carried over from the
	   previous map), send it right away too. */
	if (WatchLink_Ready())
	{
		WatchLink_SendMeta();
		watch_meta_pending = false;
	}
}

/*
 * Emit the marine's full carried inventory (item name + count) so the companion
 * can render the in-fiction "pack" -- every powerup, key, ammo type and weapon
 * the player is holding, exactly as the F1/TAB inventory screen sees it
 * (cl.inventory[] indexed into the CS_ITEMS name table). The watch surfaces the
 * powerups/keys prominently; ammo/weapon counts fill out the rest.
 *
 * Self-rate-limited: a cheap time gate first (so we don't rebuild the ~1 KB line
 * every frame), then change-detect so a static pack costs nothing. Forced out
 * fresh on (re)connect / map load via WatchLink_Reconnect clearing the cache.
 */
static void
WatchLink_SendInventory(void)
{
	char line[1100];
	char name[80];
	int i, n, off;

	if (!watch_events->value)
	{
		return;
	}

	/* Cap to ~2 Hz. Cheap gate BEFORE building the line so a firefight's
	   per-shot ammo ticks can't rebuild + diff a kilobyte 60x/second. */
	if (cls.realtime - watch_last_inv_send < 500)
	{
		return;
	}

	Q_strlcpy(line, "{\"t\":\"event\",\"kind\":\"inventory\",\"items\":[",
			sizeof(line));
	off = (int)strlen(line);

	n = 0;
	for (i = 0; i < MAX_ITEMS; i++)
	{
		if (cl.inventory[i] <= 0)
		{
			continue;
		}
		WatchLink_ConfigName(name, sizeof(name), CS_ITEMS + i);
		if (!name[0])
		{
			continue;
		}
		/* worst case appended: ,{"n":"<name>","c":NNNNN} + closing "]}\n\0" */
		if (off + (int)strlen(name) + 32 >= (int)sizeof(line))
		{
			break;
		}
		Com_sprintf(line + off, sizeof(line) - off,
				n ? ",{\"n\":\"%s\",\"c\":%d}" : "{\"n\":\"%s\",\"c\":%d}",
				name, cl.inventory[i]);
		off += (int)strlen(line + off);
		n++;
	}
	Q_strlcat(line, "]}\n", sizeof(line));

	/* Stamp the send time even when unchanged so we wait another 500ms before
	   the next rebuild; only actually transmit when the pack changed. */
	watch_last_inv_send = cls.realtime;
	if (strcmp(line, watch_last_inv) == 0)
	{
		return;
	}
	Q_strlcpy(watch_last_inv, line, sizeof(watch_last_inv));
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

	/* only meaningful once a human is actually in a level -- never stream the
	   menu attract-loop demo (it would push bogus vitals/sounds/damage). */
	if (cls.state != ca_active || !cl.frame.valid || cl.attractloop)
	{
		watch_last_flashes = 0;
		return;
	}

	/* We are in a level with a resolved destination (WatchLink_Ready passed).
	   Flush any meta queued at map load whose send had to wait for Bonjour
	   discovery to land. */
	if (watch_meta_pending)
	{
		WatchLink_SendMeta();
		watch_meta_pending = false;
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

	/* Push the carried inventory (self-rate-limited) regardless of the vitals
	   throttle below, so the marine's pack stays current even when standing still. */
	WatchLink_SendInventory();

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

	/* STAT_SELECTED_ITEM is a server-supplied short; clamp to a real item
	   slot so a bogus value can't read an unrelated configstring block. */
	WatchLink_ConfigName(sel, sizeof(sel),
			(st[STAT_SELECTED_ITEM] >= 0 && st[STAT_SELECTED_ITEM] < MAX_ITEMS)
				? (CS_ITEMS + st[STAT_SELECTED_ITEM]) : 0);
	WatchLink_ConfigName(pic, sizeof(pic),
			(st[STAT_TIMER_ICON] > 0 && st[STAT_TIMER_ICON] < MAX_IMAGES)
				? (CS_IMAGES + st[STAT_TIMER_ICON]) : 0);

	Com_sprintf(line, sizeof(line),
			"{\"t\":\"vitals\",\"game\":\"q2\","
			"\"hp\":%d,\"armor\":%d,\"ammo\":%d,"
			"\"sel\":\"%s\","
			"\"frags\":%d,\"flashes\":%d,\"layouts\":%d,\"spec\":%d,"
			"\"pu\":{\"icon\":\"%s\",\"sec\":%d}}\n",
			st[STAT_HEALTH], st[STAT_ARMOR], st[STAT_AMMO],
			sel,
			st[STAT_FRAGS], flashes, st[STAT_LAYOUTS], st[STAT_SPECTATOR],
			pic, st[STAT_TIMER]);

	/* Cut the packet flood: only send when the vitals actually changed, plus a
	   ~1 s keepalive so the companion still sees a live feed (and can detect a
	   dropout) while you stand still. Drops a steady 10 Hz down to a trickle when
	   nothing's happening, with no loss of responsiveness when it is. */
	if (strcmp(line, watch_last_vitals) == 0 &&
		cls.realtime - watch_last_send < 1000)
	{
		return;
	}

	watch_last_send = cls.realtime;
	Q_strlcpy(watch_last_vitals, line, sizeof(watch_last_vitals));
	WatchLink_Send(line);
}
