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
 * Connectionless server commands.
 *
 * =======================================================================
 */

#include "header/server.h"

extern cvar_t *hostname;
extern cvar_t *rcon_password;
char *SV_StatusString(void);

/*
 * Responds with all the info that qplug or qspy can see
 */
void
SVC_Status(void)
{
	Netchan_OutOfBandPrint(NS_SERVER, net_from, "print\n%s", SV_StatusString());
}

void
SVC_Ack(void)
{
	Com_Printf("Ping acknowledge from %s\n", NET_AdrToString(net_from));
}

/*
 * Responds with short info for broadcast scans
 * The second parameter should be the current protocol version number.
 */
void
SVC_Info(void)
{
	char string[64];
	int i, count;
	int version;

	if (maxclients->value == 1)
	{
		return; /* ignore in single player */
	}

	version = (int)strtol(Cmd_Argv(1), (char **)NULL, 10);

	if (version != PROTOCOL_VERSION)
	{
		Com_sprintf(string, sizeof(string), "%s: wrong version\n",
				hostname->string, sizeof(string));
	}
	else
	{
		count = 0;

		for (i = 0; i < maxclients->value; i++)
		{
			if (svs.clients[i].state >= cs_connected)
			{
				count++;
			}
		}

		Com_sprintf(string, sizeof(string), "%16s %8s %2i/%2i\n",
				hostname->string, sv.name, count,
				(int)maxclients->value);
	}

	Netchan_OutOfBandPrint(NS_SERVER, net_from, "info\n%s", string);
}

/*
 * SVC_Ping
 */
void
SVC_Ping(void)
{
	Netchan_OutOfBandPrint(NS_SERVER, net_from, "ack");
}

/*
 * Returns a challenge number that can be used
 * in a subsequent client_connect command.
 * We do this to prevent denial of service attacks that
 * flood the server with invalid connection IPs.  With a
 * challenge, they must give a valid IP address.
 */
void
SVC_GetChallenge(void)
{
	int i;
	int oldest;
	int oldestTime;

	oldest = 0;
	oldestTime = 0x7fffffff;

	/* see if we already have a challenge for this ip */
	for (i = 0; i < MAX_CHALLENGES; i++)
	{
		if (NET_CompareBaseAdr(net_from, svs.challenges[i].adr))
		{
			break;
		}

		if (svs.challenges[i].time < oldestTime)
		{
			oldestTime = svs.challenges[i].time;
			oldest = i;
		}
	}

	if (i == MAX_CHALLENGES)
	{
		/* overwrite the oldest */
		svs.challenges[oldest].challenge = randk() & 0x7fff;
		svs.challenges[oldest].adr = net_from;
		svs.challenges[oldest].time = curtime;
		i = oldest;
	}

	/* send it back */
	Netchan_OutOfBandPrint(NS_SERVER, net_from, "challenge %i",
			svs.challenges[i].challenge);
}

/*
 * A connection request that did not come from the master
 */
void
SVC_DirectConnect(void)
{
	char userinfo[MAX_INFO_STRING];
	netadr_t adr;
	int i;
	client_t *cl, *newcl;
	client_t temp;
	edict_t *ent;
	int edictnum;
	int version;
	int qport;
	int challenge;

	adr = net_from;

	Com_DPrintf("SVC_DirectConnect ()\n");

	version = (int)strtol(Cmd_Argv(1), (char **)NULL, 10);

	if (version != PROTOCOL_VERSION)
	{
		Netchan_OutOfBandPrint(NS_SERVER, adr,
				"print\nServer is version %s.\n", VERSION);
		Com_DPrintf("    rejected connect from version %i\n", version);
		return;
	}

	qport = (int)strtol(Cmd_Argv(2), (char **)NULL, 10);

	challenge = (int)strtol(Cmd_Argv(3), (char **)NULL, 10);

	Q_strlcpy(userinfo, Cmd_Argv(4), sizeof(userinfo));

	/* force the IP key/value pair so the game can filter based on ip */
	Info_SetValueForKey(userinfo, "ip", NET_AdrToString(net_from));

	/* attractloop servers are ONLY for local clients */
	if (sv.attractloop)
	{
		if (!NET_IsLocalAddress(adr))
		{
			Com_Printf("Remote connect in attract loop.  Ignored.\n");
			Netchan_OutOfBandPrint(NS_SERVER, adr,
					"print\nConnection refused.\n");
			return;
		}
	}

	/* see if the challenge is valid */
	if (!NET_IsLocalAddress(adr))
	{
		for (i = 0; i < MAX_CHALLENGES; i++)
		{
			if (NET_CompareBaseAdr(net_from, svs.challenges[i].adr))
			{
				if (challenge == svs.challenges[i].challenge)
				{
					break; /* good */
				}

				Netchan_OutOfBandPrint(NS_SERVER, adr,
						"print\nBad challenge.\n");
				return;
			}
		}

		if (i == MAX_CHALLENGES)
		{
			Netchan_OutOfBandPrint(NS_SERVER, adr,
					"print\nNo challenge for address.\n");
			return;
		}
	}

	newcl = &temp;
	memset(newcl, 0, sizeof(client_t));

	/* if there is already a slot for this ip, reuse it */
	for (i = 0, cl = svs.clients; i < maxclients->value; i++, cl++)
	{
		if (cl->state < cs_connected)
		{
			continue;
		}

		if (NET_CompareBaseAdr(adr, cl->netchan.remote_address) &&
			((cl->netchan.qport == qport) ||
			 (adr.port == cl->netchan.remote_address.port)))
		{
			if (!NET_IsLocalAddress(adr))
			{
				Com_DPrintf("%s:reconnect rejected : too soon\n",
						NET_AdrToString(adr));
				return;
			}

			Com_Printf("%s:reconnect\n", NET_AdrToString(adr));
			newcl = cl;
			goto gotnewcl;
		}
	}

	/* find a client slot */
	newcl = NULL;

	for (i = 0, cl = svs.clients; i < maxclients->value; i++, cl++)
	{
		if (cl->state == cs_free)
		{
			newcl = cl;
			break;
		}
	}

	if (!newcl)
	{
		Netchan_OutOfBandPrint(NS_SERVER, adr, "print\nServer is full.\n");
		Com_DPrintf("Rejected a connection.\n");
		return;
	}

gotnewcl:

	/* build a new connection  accept the new client this
	   is the only place a client_t is ever initialized */
	*newcl = temp;
	sv_client = newcl;
	edictnum = (newcl - svs.clients) + 1;
	ent = EDICT_NUM(edictnum);
	newcl->edict = ent;
	newcl->challenge = challenge; /* save challenge for checksumming */

	/* get the game a chance to reject this connection or modify the userinfo */
	if (!(ge->ClientConnect(ent, userinfo)))
	{
		if (*Info_ValueForKey(userinfo, "rejmsg"))
		{
			Netchan_OutOfBandPrint(NS_SERVER, adr,
					"print\n%s\nConnection refused.\n",
					Info_ValueForKey(userinfo, "rejmsg"));
		}
		else
		{
			Netchan_OutOfBandPrint(NS_SERVER, adr,
					"print\nConnection refused.\n");
		}

		Com_DPrintf("Game rejected a connection.\n");
		return;
	}

	/* parse some info from the info strings */
	Q_strlcpy(newcl->userinfo, userinfo, sizeof(newcl->userinfo));
	SV_UserinfoChanged(newcl);

	/* send the connect packet to the client */
	Netchan_OutOfBandPrint(NS_SERVER, adr, "client_connect");

	Netchan_Setup(NS_SERVER, &newcl->netchan, adr, qport);

	newcl->state = cs_connected;

	SZ_Init(&newcl->datagram, newcl->datagram_buf, sizeof(newcl->datagram_buf));
	newcl->datagram.allowoverflow = true;
	newcl->lastmessage = svs.realtime;  /* don't timeout */
	newcl->lastconnect = svs.realtime;
}

int
Rcon_Validate(void)
{
	if (!strlen(rcon_password->string))
	{
		return 0;
	}

	if (strcmp(Cmd_Argv(1), rcon_password->string))
	{
		return 0;
	}

	return 1;
}

/*
 * A client issued an rcon command.
 * Shift down the remaining args
 * Redirect all printfs
 */
void
SVC_RemoteCommand(void)
{
	int i;
	char remaining[1024];

	i = Rcon_Validate();

	if (i == 0)
	{
		Com_Printf("Bad rcon from %s:\n%s\n", NET_AdrToString(
						net_from), net_message.data + 4);
	}
	else
	{
		Com_Printf("Rcon from %s:\n%s\n", NET_AdrToString(
						net_from), net_message.data + 4);
	}

	Com_BeginRedirect(RD_PACKET, sv_outputbuf,
			SV_OUTPUTBUF_LENGTH, SV_FlushRedirect);

	if (!Rcon_Validate())
	{
		Com_Printf("Bad rcon_password.\n");
	}
	else
	{
		remaining[0] = 0;

		for (i = 2; i < Cmd_Argc(); i++)
		{
			strcat(remaining, Cmd_Argv(i));
			strcat(remaining, " ");
		}

		Cmd_ExecuteString(remaining);
	}

	Com_EndRedirect();
}

/*
 * =======================================================================
 *
 * CONNECTIONLESS RATE LIMIT
 *
 * A leaky bucket per source address, so an unauthenticated query cannot be
 * used to point this server's replies at somebody else.
 *
 * Why it is needed. Every handler above runs before any client is accepted:
 * no password, no `public` check, no address check. The source address of a
 * UDP packet is whatever the sender writes in it, so a stranger can send
 * small packets carrying a victim's address and have this server deliver the
 * flood, under this machine's IP. Measured on this exact build (ADR 0011), a
 * 10-byte `status` query is answered with 228 bytes, which is 23x, and there
 * was no rate limit anywhere in the yquake2 server.
 *
 * A firewall allowlist is the primary defence and it works, because a spoofed
 * packet claims to come from the victim rather than from the attacker, so the
 * allowlist drops it. This exists so that a mistake in one ufw or nft rule is
 * the difference between annoying and catastrophic, rather than the only
 * thing standing between the box and being a usable reflector. Both, not
 * either.
 *
 * Ported from ioquake3's sv_main.c, which has carried this for years, by way
 * of the same change made to the sister Half-Life port's engine. Two
 * deliberate differences from ioquake3: time is kept as double seconds, and
 * the address is hashed field by field rather than over the whole netadr_t,
 * because netadr_t has padding and padding bytes are not initialised.
 *
 * =======================================================================
 */
#define MAX_RATE_BUCKETS 1024   /* distinct addresses tracked at once */
#define MAX_RATE_HASHES 256

typedef struct leakybucket_s
{
	netadr_t adr;
	qboolean inuse;              /* an explicit flag, see SV_BucketForAddress */
	double lasttime;             /* server time at the last accounting */
	int burst;
	int hash;
	struct leakybucket_s *prev, *next;
} leakybucket_t;

static leakybucket_t sv_buckets[MAX_RATE_BUCKETS];
static leakybucket_t *sv_buckethashes[MAX_RATE_HASHES];

/*
 * svs.realtime is milliseconds and its header calls it "always increasing",
 * which is not true: SV_Frame winds it back to sv.time - 100 when the server
 * runs ahead, and SV_InitGame zeroes the whole of svs on a restart. Both
 * cases show up here as a negative interval, and both are handled by
 * resetting the bucket rather than by trusting the clock.
 */
static double
SV_RateTime(void)
{
	return (double)svs.realtime * 0.001;
}

static int
SV_HashForAddress(const netadr_t *adr)
{
	int hash = 0;
	int i, n = 0;

	/* Everything that identifies the host, and deliberately not the port:
	   varying the source port costs an attacker nothing, so one host has to
	   land in one bucket however many ports it sends from. */
	hash += (int)adr->type * (n++ + 119);

	for (i = 0; i < (int)sizeof(adr->ip); i++)
	{
		hash += (int)adr->ip[i] * (n++ + 119);
	}

	for (i = 0; i < (int)sizeof(adr->ipx); i++)
	{
		hash += (int)adr->ipx[i] * (n++ + 119);
	}

	for (i = 0; i < (int)sizeof(adr->scope_id); i++)
	{
		hash += (int)((adr->scope_id >> (i * 8)) & 0xff) * (n++ + 119);
	}

	hash = hash ^ (hash >> 10) ^ (hash >> 20);

	return hash & (MAX_RATE_HASHES - 1);
}

static leakybucket_t *
SV_BucketForAddress(netadr_t adr, int burst, double period)
{
	leakybucket_t *bucket;
	int hash = SV_HashForAddress(&adr);
	int i;

	for (bucket = sv_buckethashes[hash]; bucket; bucket = bucket->next)
	{
		if (NET_CompareBaseAdr(bucket->adr, adr))
		{
			return bucket;
		}
	}

	for (i = 0; i < MAX_RATE_BUCKETS; i++)
	{
		bucket = &sv_buckets[i];

		/* Reclaim a bucket that has had time to drain completely. The
		   interval < 0 case catches the clock moving backwards, which
		   would otherwise strand the bucket forever. */
		if (bucket->inuse)
		{
			double interval = SV_RateTime() - bucket->lasttime;

			if ((interval > (burst * period)) || (interval < 0.0))
			{
				if (bucket->prev != NULL)
				{
					bucket->prev->next = bucket->next;
				}
				else
				{
					sv_buckethashes[bucket->hash] = bucket->next;
				}

				if (bucket->next != NULL)
				{
					bucket->next->prev = bucket->prev;
				}

				memset(bucket, 0, sizeof(*bucket));
			}
		}

		if (!bucket->inuse)
		{
			/* An explicit flag rather than an empty-looking address or a
			   zero timestamp: NA_LOOPBACK is 0 in netadrtype_t, so a zeroed
			   bucket and a real loopback bucket have the same type, and
			   svs.realtime is genuinely 0 for the first frames after a
			   restart, so a zero lasttime does not mean free either. */
			bucket->adr = adr;
			bucket->inuse = true;
			bucket->lasttime = SV_RateTime();
			bucket->burst = 0;
			bucket->hash = hash;

			bucket->next = sv_buckethashes[hash];

			if (sv_buckethashes[hash] != NULL)
			{
				sv_buckethashes[hash]->prev = bucket;
			}

			bucket->prev = NULL;
			sv_buckethashes[hash] = bucket;

			return bucket;
		}
	}

	/* Every bucket is in use and none has drained. That is either a real
	   flood from many addresses or a deliberate attempt to exhaust the
	   table, and in both cases the safe answer is to say no. */
	return NULL;
}

/*
 * true means "over the limit, drop it". A NULL bucket, meaning the table is
 * full, also means true: fail closed, never open.
 */
qboolean
SV_RateLimitAddress(netadr_t adr, int burst, double period)
{
	leakybucket_t *bucket;
	double interval;
	int expired;

	if ((burst <= 0) || (period <= 0.0))
	{
		return false; /* disabled */
	}

	bucket = SV_BucketForAddress(adr, burst, period);

	if (bucket == NULL)
	{
		return true;
	}

	interval = SV_RateTime() - bucket->lasttime;

	if (interval < 0.0)
	{
		interval = 0.0;
	}

	expired = (int)(interval / period);

	if (expired > bucket->burst)
	{
		bucket->burst = 0;
		bucket->lasttime = SV_RateTime();
	}
	else
	{
		bucket->burst -= expired;
		bucket->lasttime = SV_RateTime() - (interval - (expired * period));
	}

	if (bucket->burst < burst)
	{
		bucket->burst++;
		return false;
	}

	return true;
}

/*
 * Which connectionless commands are gated, and why the rest are not.
 *
 * Gated: `status` and `info`, the two measured amplifiers; `ping`, whose
 * reply is small but still bigger than nothing and costs an attacker nothing
 * to ask for; and `rcon`, which answers a wrong password with a packet and
 * writes the whole datagram to the console, so ungated it is both a reflector
 * and an unlimited dictionary attack against rcon_password. ioquake3 rate
 * limits its rcon for exactly that reason.
 *
 * Deliberately not gated: `connect` and `getchallenge`, because throttling
 * those throttles joining, which is the thing the server is for; and `ack`,
 * which sends no reply.
 */
static qboolean
SV_ConnectionlessQueryLimited(const char *c)
{
	qboolean amplifying;

	amplifying = !strcmp(c, "status") || !strcmp(c, "info") ||
				 !strcmp(c, "ping") || !strcmp(c, "rcon");

	if (!amplifying)
	{
		return false;
	}

	return SV_RateLimitAddress(net_from, (int)sv_query_rate_burst->value,
			(double)sv_query_rate_period->value);
}

/*
 * A connectionless packet has four leading 0xff
 * characters to distinguish it from a game channel.
 * Clients that are in the game can still send
 * connectionless packets.
 */
void
SV_ConnectionlessPacket(void)
{
	char *s;
	char *c;

	MSG_BeginReading(&net_message);
	MSG_ReadLong(&net_message); /* skip the -1 marker */

	s = MSG_ReadStringLine(&net_message);

	Cmd_TokenizeString(s, false);

	c = Cmd_Argv(0);
	Com_DPrintf("Packet %s : %s\n", NET_AdrToString(net_from), c);

	if (SV_ConnectionlessQueryLimited(c))
	{
		return;
	}

	if (!strcmp(c, "ping"))
	{
		SVC_Ping();
	}
	else if (!strcmp(c, "ack"))
	{
		SVC_Ack();
	}
	else if (!strcmp(c, "status"))
	{
		SVC_Status();
	}
	else if (!strcmp(c, "info"))
	{
		SVC_Info();
	}
	else if (!strcmp(c, "getchallenge"))
	{
		SVC_GetChallenge();
	}
	else if (!strcmp(c, "connect"))
	{
		SVC_DirectConnect();
	}
	else if (!strcmp(c, "rcon"))
	{
		SVC_RemoteCommand();
	}
	else
	{
		Com_Printf("bad connectionless packet from %s:\n%s\n",
				NET_AdrToString(net_from), s);
	}
}

