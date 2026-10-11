// toe_csim -- models around the Coyote TOE for C simulation in non-bypass mode (RX_DDR_BYPASS = 0).
//
// Byte streams, word packing, the card-memory model (datamover command/status semantics) and
// IPv4/TCP packet building/parsing with real checksums. The testbench proper (peer, app, cases) is
// toe_csim_tb.cpp.
#pragma once

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <string>
#include <vector>

#include "toe_config.hpp"
#include "toe.hpp"
#include "toe_internals.hpp"
#include "session_lookup_controller/session_lookup_controller.hpp"

#if RX_DDR_BYPASS
#error "toe_csim drives the TOE with its receive ring in card memory: generate toe_config.hpp with RX_DDR_BYPASS 0"
#endif

#if defined(__VITIS_HLS__)
typedef ap_axiu<DATA_WIDTH, 0, 0, 0> TopWord;
#else
typedef net_axis<DATA_WIDTH> TopWord;
#endif

static const int WBYTES = DATA_WIDTH / 8;

// ------------------------------------------------------------------------------------------------
// failure bookkeeping (one case per process, so globals are fine)
// ------------------------------------------------------------------------------------------------
static uint64_t g_cycle = 0;
static bool g_failed = false;
static std::string g_failmsg;

static void tbFail(const char* fmt, ...)
{
	char buf[1024];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	if (!g_failed)
	{
		g_failed = true;
		g_failmsg = buf;
	}
	fprintf(stdout, "TB FAIL @%llu: %s\n", (unsigned long long)g_cycle, buf);
	fflush(stdout);
}

static void tbInfo(const char* fmt, ...)
{
	char buf[1024];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	fprintf(stdout, "TB @%llu: %s\n", (unsigned long long)g_cycle, buf);
	fflush(stdout);
}

// ------------------------------------------------------------------------------------------------
// deterministic payload: byte `off` of stream `stream` under `seed`
// ------------------------------------------------------------------------------------------------
static inline uint8_t genByte(uint32_t seed, uint32_t stream, uint64_t off)
{
	uint64_t x = off * 0x9E3779B97F4A7C15ull ^ ((uint64_t)stream << 44) ^ ((uint64_t)seed << 20);
	x ^= x >> 29;
	x *= 0xBF58476D1CE4E5B9ull;
	x ^= x >> 32;
	return (uint8_t)x;
}

struct Rng
{
	uint64_t s;
	explicit Rng(uint64_t seed) : s(seed * 0x9E3779B97F4A7C15ull + 1) {}
	uint32_t next()
	{
		s ^= s << 13;
		s ^= s >> 7;
		s ^= s << 17;
		return (uint32_t)(s >> 11);
	}
	uint32_t range(uint32_t lo, uint32_t hi) { return lo + next() % (hi - lo + 1); } // inclusive
};

// sequence-number arithmetic (RFC 1982)
static inline int32_t seqDiff(uint32_t a, uint32_t b) { return (int32_t)(a - b); }
static inline bool seqLt(uint32_t a, uint32_t b) { return seqDiff(a, b) < 0; }

// ------------------------------------------------------------------------------------------------
// word packing: byte i of a beat is data(8i+7, 8i); keep is contiguous from bit 0
// ------------------------------------------------------------------------------------------------
static inline uint64_t keepMask(int n) { return n >= 64 ? ~0ull : ((1ull << n) - 1); }

static TopWord packWord(const uint8_t* b, int n, bool last)
{
	TopWord w;
	ap_uint<DATA_WIDTH> d = 0;
	for (int j = 0; j < WBYTES / 8; j++)
	{
		uint64_t v = 0;
		for (int k = 0; k < 8; k++)
		{
			int i = j * 8 + k;
			if (i < n)
				v |= (uint64_t)b[i] << (8 * k);
		}
		d(64 * j + 63, 64 * j) = v;
	}
	w.data = d;
	w.keep = ap_uint<WBYTES>(keepMask(n));
	w.last = last ? 1 : 0;
	return w;
}

// returns the number of valid bytes; `contiguous` says whether keep was 1..10..0
static int unpackWord(const TopWord& w, uint8_t* b, bool& contiguous)
{
	uint64_t k = w.keep.to_uint64();
	int n = __builtin_popcountll(k);
	contiguous = (k == keepMask(n));
	ap_uint<DATA_WIDTH> d = w.data;
	for (int j = 0; j < WBYTES / 8; j++)
	{
		uint64_t v = d(64 * j + 63, 64 * j).to_uint64();
		for (int kk = 0; kk < 8; kk++)
			b[j * 8 + kk] = (uint8_t)(v >> (8 * kk));
	}
	return n;
}

// ------------------------------------------------------------------------------------------------
// card memory behind the datamover (Coyote: tcp_mem_intf -> axi_datamover_mem_unaligned, DRE on)
//
// Per session a ring of BUFFER_SIZE bytes: id = saddr(29, WINDOW_BITS), offset = saddr(WINDOW_BITS-1, 0).
// A command must stay inside its ring (offset + btt <= BUFFER_SIZE): the TOE splits at the ring end
// itself. Write data is packed from byte lane 0, keep contiguous, full beats except the last, tlast on
// exactly the last beat of each command; one status per command, in order, after `latW` cycles.
// Read data is returned the same way after `latR` cycles. Unwritten bytes read as 0xEE.
// ------------------------------------------------------------------------------------------------
struct MemModel
{
	struct Cmd
	{
		uint32_t sid, off, len;
	};

	const char* name;
	int latW, latR, stallPct;
	Rng rng;
	std::map<uint32_t, std::vector<uint8_t> > rings;

	std::deque<Cmd> wrQ;
	bool wrActive = false;
	Cmd wrCur;
	uint32_t wrDone = 0;
	std::deque<std::pair<uint64_t, mmStatus> > stsQ;

	std::deque<std::pair<uint64_t, Cmd> > rdQ;
	bool rdActive = false;
	Cmd rdCur;
	uint32_t rdDone = 0;

	// statistics / coverage
	uint64_t nWrCmd = 0, nRdCmd = 0, wrBytes = 0, rdBytes = 0;
	uint64_t nWrEndAtRingEndUnaligned = 0; // write commands ending exactly at the ring end, len % 64 != 0
	uint64_t nWrStartAtZero = 0;           // write commands starting at offset 0 (second half of a split)
	uint64_t nRdEndAtRingEnd = 0, nRdStartAtZero = 0;

	MemModel(const char* n, int lw, int lr, int stall, uint64_t seed)
		: name(n), latW(lw), latR(lr), stallPct(stall), rng(seed) {}

	uint8_t* ring(uint32_t sid)
	{
		std::map<uint32_t, std::vector<uint8_t> >::iterator it = rings.find(sid);
		if (it == rings.end())
			it = rings.insert(std::make_pair(sid, std::vector<uint8_t>(BUFFER_SIZE, 0xEE))).first;
		return it->second.data();
	}

	bool decode(const mmCmd& c, Cmd& out, const char* kind)
	{
		uint32_t addr = (uint32_t)c.saddr;
		uint32_t len = (uint32_t)c.bbt;
		out.sid = (addr >> WINDOW_BITS) & ((1u << (30 - WINDOW_BITS)) - 1);
		out.off = addr & (BUFFER_SIZE - 1);
		out.len = len;
		if ((addr >> 30) != 0)
		{
			tbFail("%s %s cmd: saddr bits 31:30 set (0x%08x)", name, kind, addr);
			return false;
		}
		if (len == 0)
		{
			tbFail("%s %s cmd: zero-length command at 0x%08x", name, kind, addr);
			return false;
		}
		if ((uint64_t)out.off + len > BUFFER_SIZE)
		{
			tbFail("%s %s cmd crosses the end of session %u's ring: off 0x%05x + len %u > 0x%x", name, kind,
				   out.sid, out.off, len, BUFFER_SIZE);
			return false;
		}
		if (out.sid >= MAX_SESSIONS)
		{
			tbFail("%s %s cmd: session id %u out of range", name, kind, out.sid);
			return false;
		}
		if (c.type != 1 || c.eof != 1)
		{
			tbFail("%s %s cmd: type %d eof %d (expected 1/1)", name, kind, (int)c.type, (int)c.eof);
			return false;
		}
		return true;
	}

	void step(hls::stream<mmCmd>& wrCmd, hls::stream<TopWord>& wrData, hls::stream<mmStatus>& wrSts,
			  hls::stream<mmCmd>& rdCmd, hls::stream<TopWord>& rdData)
	{
		// commands
		while (!wrCmd.empty())
		{
			Cmd c;
			if (!decode(wrCmd.read(), c, "write"))
				return;
			wrQ.push_back(c);
			nWrCmd++;
			if (c.off + c.len == BUFFER_SIZE && (c.len % WBYTES) != 0)
				nWrEndAtRingEndUnaligned++;
			if (c.off == 0)
				nWrStartAtZero++;
		}
		while (!rdCmd.empty())
		{
			Cmd c;
			if (!decode(rdCmd.read(), c, "read"))
				return;
			rdQ.push_back(std::make_pair(g_cycle + latR, c));
			nRdCmd++;
			if (c.off + c.len == BUFFER_SIZE)
				nRdEndAtRingEnd++;
			if (c.off == 0)
				nRdStartAtZero++;
		}
		bool stall = stallPct > 0 && (int)(rng.next() % 100) < stallPct;
		// write data: one beat per cycle
		if (!stall)
		{
			if (!wrActive && !wrQ.empty())
			{
				wrCur = wrQ.front();
				wrQ.pop_front();
				wrActive = true;
				wrDone = 0;
			}
			if (wrActive && !wrData.empty())
			{
				TopWord w = wrData.read();
				uint8_t b[WBYTES];
				bool contig;
				int n = unpackWord(w, b, contig);
				uint32_t left = wrCur.len - wrDone;
				if (!contig || n == 0)
				{
					tbFail("%s write data: keep 0x%016llx not contiguous from lane 0", name,
						   (unsigned long long)w.keep.to_uint64());
					return;
				}
				if ((uint32_t)n > left)
				{
					tbFail("%s write data overruns the command (sid %u off 0x%05x len %u, %u left, beat has %d)",
						   name, wrCur.sid, wrCur.off, wrCur.len, left, n);
					return;
				}
				if ((uint32_t)n < left && n != WBYTES)
				{
					tbFail("%s write data: partial beat (%d bytes) before the end of the command", name, n);
					return;
				}
				bool lastExpected = ((uint32_t)n == left);
				if ((w.last == 1) != lastExpected)
				{
					tbFail("%s write data: tlast=%d but %u of %u bytes remain after this beat (sid %u off 0x%05x)",
						   name, (int)w.last, left - n, wrCur.len, wrCur.sid, wrCur.off);
					return;
				}
				uint8_t* r = ring(wrCur.sid);
				memcpy(r + wrCur.off + wrDone, b, n);
				wrDone += n;
				wrBytes += n;
				if (wrDone == wrCur.len)
				{
					mmStatus s;
					s.tag = 0;
					s.interr = 0;
					s.decerr = 0;
					s.slverr = 0;
					s.okay = 1;
					stsQ.push_back(std::make_pair(g_cycle + latW, s));
					wrActive = false;
				}
			}
		}
		if (!stsQ.empty() && stsQ.front().first <= g_cycle)
		{
			wrSts.write(stsQ.front().second);
			stsQ.pop_front();
		}
		// read data: one beat per cycle
		if (!stall)
		{
			if (!rdActive && !rdQ.empty() && rdQ.front().first <= g_cycle)
			{
				rdCur = rdQ.front().second;
				rdQ.pop_front();
				rdActive = true;
				rdDone = 0;
			}
			if (rdActive)
			{
				uint32_t n = rdCur.len - rdDone;
				if (n > (uint32_t)WBYTES)
					n = WBYTES;
				const uint8_t* r = ring(rdCur.sid);
				rdData.write(packWord(r + rdCur.off + rdDone, n, rdDone + n == rdCur.len));
				rdDone += n;
				rdBytes += n;
				if (rdDone == rdCur.len)
					rdActive = false;
			}
		}
	}
};

// ------------------------------------------------------------------------------------------------
// IPv4 + TCP
// ------------------------------------------------------------------------------------------------
enum
{
	F_FIN = 0x01,
	F_SYN = 0x02,
	F_RST = 0x04,
	F_PSH = 0x08,
	F_ACK = 0x10
};

static uint32_t csumAdd(uint32_t sum, const uint8_t* p, size_t n)
{
	for (size_t i = 0; i + 1 < n; i += 2)
		sum += ((uint32_t)p[i] << 8) | p[i + 1];
	if (n & 1)
		sum += (uint32_t)p[n - 1] << 8;
	return sum;
}
static uint16_t csumFin(uint32_t s)
{
	while (s >> 16)
		s = (s & 0xFFFF) + (s >> 16);
	return (uint16_t)(~s & 0xFFFF);
}
static inline void put16(uint8_t* p, uint16_t v)
{
	p[0] = v >> 8;
	p[1] = v & 0xFF;
}
static inline void put32(uint8_t* p, uint32_t v)
{
	p[0] = v >> 24;
	p[1] = (v >> 16) & 0xFF;
	p[2] = (v >> 8) & 0xFF;
	p[3] = v & 0xFF;
}
static inline uint16_t get16(const uint8_t* p) { return ((uint16_t)p[0] << 8) | p[1]; }
static inline uint32_t get32(const uint8_t* p)
{
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

// IPs and ports in host order (10.0.0.2 == 0x0A000002)
static std::vector<uint8_t> buildTcp(uint32_t sip, uint32_t dip, uint16_t sp, uint16_t dp, uint32_t seq, uint32_t ack,
									 uint8_t flags, uint16_t win, const std::vector<uint8_t>& opts,
									 const uint8_t* pay, size_t plen)
{
	size_t optLen = (opts.size() + 3) & ~(size_t)3;
	size_t tcpLen = 20 + optLen + plen;
	size_t total = 20 + tcpLen;
	std::vector<uint8_t> b(total, 0);
	static uint16_t ipId = 1;
	uint8_t* ip = b.data();
	ip[0] = 0x45;
	put16(ip + 2, (uint16_t)total);
	put16(ip + 4, ipId++);
	put16(ip + 6, 0x4000);
	ip[8] = 64;
	ip[9] = 6;
	put32(ip + 12, sip);
	put32(ip + 16, dip);
	put16(ip + 10, csumFin(csumAdd(0, ip, 20)));
	uint8_t* t = ip + 20;
	put16(t + 0, sp);
	put16(t + 2, dp);
	put32(t + 4, seq);
	put32(t + 8, ack);
	t[12] = (uint8_t)(((20 + optLen) / 4) << 4);
	t[13] = flags;
	put16(t + 14, win);
	if (!opts.empty())
		memcpy(t + 20, opts.data(), opts.size());
	if (plen)
		memcpy(t + 20 + optLen, pay, plen);
	uint8_t ph[12];
	put32(ph, sip);
	put32(ph + 4, dip);
	ph[8] = 0;
	ph[9] = 6;
	put16(ph + 10, (uint16_t)tcpLen);
	uint32_t s = csumAdd(0, ph, 12);
	s = csumAdd(s, t, tcpLen);
	put16(t + 16, csumFin(s));
	return b;
}

struct TcpPkt
{
	bool ok = false;
	std::string err;
	uint32_t sip = 0, dip = 0;
	uint16_t sp = 0, dp = 0;
	uint32_t seq = 0, ack = 0;
	uint8_t flags = 0;
	uint16_t win = 0;
	int mss = -1, ws = -1;
	std::vector<uint8_t> pay;
};

// checkIpCsum: the TOE leaves the IPv4 header checksum to the IP stack behind it (generate_ipv4 never
// fills it), so packets the TOE emits are parsed with checkIpCsum = false
static TcpPkt parseTcp(const std::vector<uint8_t>& b, bool checkIpCsum)
{
	TcpPkt p;
	if (b.size() < 40)
	{
		p.err = "packet shorter than 40 bytes";
		return p;
	}
	const uint8_t* ip = b.data();
	int ihl = (ip[0] & 0xF) * 4;
	uint16_t total = get16(ip + 2);
	if ((ip[0] >> 4) != 4 || ihl < 20 || ip[9] != 6)
	{
		p.err = "not IPv4/TCP";
		return p;
	}
	if (total != b.size())
	{
		char m[96];
		snprintf(m, sizeof(m), "IP total length %u but %zu bytes on the stream", total, b.size());
		p.err = m;
		return p;
	}
	if (checkIpCsum && csumFin(csumAdd(0, ip, ihl)) != 0)
	{
		p.err = "bad IPv4 header checksum";
		return p;
	}
	p.sip = get32(ip + 12);
	p.dip = get32(ip + 16);
	const uint8_t* t = ip + ihl;
	size_t tcpLen = total - ihl;
	int doff = (t[12] >> 4) * 4;
	if (doff < 20 || (size_t)doff > tcpLen)
	{
		p.err = "bad TCP data offset";
		return p;
	}
	uint8_t ph[12];
	put32(ph, p.sip);
	put32(ph + 4, p.dip);
	ph[8] = 0;
	ph[9] = 6;
	put16(ph + 10, (uint16_t)tcpLen);
	uint32_t s = csumAdd(0, ph, 12);
	s = csumAdd(s, t, tcpLen);
	if (csumFin(s) != 0)
	{
		p.err = "bad TCP checksum";
		return p;
	}
	p.sp = get16(t);
	p.dp = get16(t + 2);
	p.seq = get32(t + 4);
	p.ack = get32(t + 8);
	p.flags = t[13];
	p.win = get16(t + 14);
	for (int i = 20; i < doff;)
	{
		uint8_t kind = t[i];
		if (kind == 0)
			break;
		if (kind == 1)
		{
			i++;
			continue;
		}
		if (i + 1 >= doff)
			break;
		uint8_t len = t[i + 1];
		if (len < 2 || i + len > doff)
			break;
		if (kind == 2 && len == 4)
			p.mss = get16(t + i + 2);
		if (kind == 3 && len == 3)
			p.ws = t[i + 2];
		i += len;
	}
	p.pay.assign(t + doff, t + tcpLen);
	p.ok = true;
	return p;
}
