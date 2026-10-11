// toe_csim -- C simulation of the Coyote TOE (toe_top) with its receive ring in card memory
// (RX_DDR_BYPASS = 0), 512-bit data path, window scaling on, WINDOW_BITS 20 (1 MiB per session).
//
// The testbench is the whole outside world of toe_top, one call = one cycle:
//   * the remote server ("peer"): answers the TOE's SYN with SYN-ACK (window scale 7 like Linux, or
//     none), sends data segments with real IPv4/TCP checksums, keeps a Linux-like sender (window,
//     go-back-N retransmission timeout, zero-window probes at seq = snd_una - 1) and acknowledges
//     what the TOE sends; it checks every ACK's window against the ring's real free space;
//   * the application: opens connections, counts notified bytes per session, issues readPkg in an
//     order and with lengths each case chooses, and checks every returned byte; it can also send;
//   * card memory behind the datamover (tb_model.hpp: per-session 1 MiB rings, command/status
//     formats, unaligned addresses, tlast per command); the session-lookup CAM.
//
// Each case runs in its own forked process (fresh TOE statics), all cases in parallel; the parent
// prints one line per case. Per-case logs go to $TOE_CSIM_LOGDIR (default: the working directory).
// $TOE_CSIM_LAT / $TOE_CSIM_STALL override every case's card-memory latency and stall percentage.
//
//   csim.exe            all cases
//   csim.exe c1,c4      a selection

#include "tb_model.hpp"

#include <fcntl.h>
#include <functional>
#include <memory>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

void toe_top(hls::stream<TopWord>& ipRxData, hls::stream<mmStatus>& rxBufferWriteStatus,
			 hls::stream<mmStatus>& txBufferWriteStatus, hls::stream<TopWord>& rxBufferReadData,
			 hls::stream<TopWord>& txBufferReadData, hls::stream<TopWord>& ipTxData, hls::stream<mmCmd>& rxBufferWriteCmd,
			 hls::stream<mmCmd>& rxBufferReadCmd, hls::stream<mmCmd>& txBufferWriteCmd, hls::stream<mmCmd>& txBufferReadCmd,
			 hls::stream<TopWord>& rxBufferWriteData, hls::stream<TopWord>& txBufferWriteData,
			 hls::stream<rtlSessionLookupReply>& sessionLookup_rsp, hls::stream<rtlSessionUpdateReply>& sessionUpdate_rsp,
			 hls::stream<rtlSessionLookupRequest>& sessionLookup_req, hls::stream<rtlSessionUpdateRequest>& sessionUpdate_req,
			 hls::stream<ap_uint<16> >& listenPortReq, hls::stream<appReadRequest>& rxDataReq,
			 hls::stream<ipTuple>& openConnReq, hls::stream<ap_uint<16> >& closeConnReq,
			 hls::stream<appTxMeta>& txDataReqMeta, hls::stream<TopWord>& txDataReq, hls::stream<bool>& listenPortRsp,
			 hls::stream<appNotification>& notification, hls::stream<ap_uint<16> >& rxDataRspMeta,
			 hls::stream<TopWord>& rxDataRsp, hls::stream<openStatus>& openConnRsp, hls::stream<appTxRsp>& txDataRsp,
			 ap_uint<32> myIpAddress, ap_uint<16>& regSessionCount);

static const uint32_t TOE_IP = 0x0A000001; // 10.0.0.1
static const uint32_t SRV_IP = 0x0A000002; // 10.0.0.2
static const uint16_t SRV_PORT = 9000;
static const uint32_t RING = BUFFER_SIZE;
static const uint64_t NO_LIMIT = ~0ull;

// ------------------------------------------------------------------------------------------------
// one connection: configuration, the peer's view, the app's view
// ------------------------------------------------------------------------------------------------
struct Sess
{
	int idx = 0;
	// configuration
	uint32_t isnPeer = 0x12345677;
	bool ws = true;    // peer offers window scaling in its SYN-ACK
	int peerShift = 7; // ...with this shift (Linux default)
	uint16_t peerMss = 4096;
	bool passive = false;    // the peer connects to a port the app listens on (c9)
	uint16_t listenPort = 0; // ...this one
	uint64_t rxLen = 0; // bytes the peer sends to the TOE
	std::vector<uint32_t> segSizes = std::vector<uint32_t>(1, 1448);
	// TOE side, learnt from the handshake
	int sid = -1;
	bool opened = false;
	uint16_t toePort = 0;
	uint32_t isnToe = 0;
	int toeShift = -1;
	bool synSeen = false, established = false;
	// peer sender
	bool autoSend = false;
	uint64_t autoLimit = NO_LIMIT; // the automatic sender stops at this stream offset
	uint32_t sndUna = 0, sndNxt = 0, maxSent = 0;
	uint32_t wndRight = 0, maxRight = 0;
	bool haveWnd = false;
	uint64_t lastProgress = 0, lastProbe = 0;
	size_t segIdx = 0;
	uint64_t rto = 6000, probeInt = 3000;
	uint64_t nRto = 0, nProbe = 0, nAcks = 0, nDupAcks = 0, nToePkts = 0, nSegsSent = 0;
	uint32_t lastAck = 0;
	uint16_t lastWin = 0;
	// peer receiver (data the TOE sends)
	uint32_t rcvNxt = 0;
	uint64_t txRecv = 0, nTxSegs = 0, nTxDropped = 0;
	std::function<bool(uint32_t, uint32_t)> dropTx;
	// application
	uint64_t notified = 0, requested = 0, verified = 0;
	bool closedNotif = false;
	uint64_t txQueued = 0; // app bytes the TOE accepted for sending

	uint32_t base() const { return isnPeer + 1; }
	uint64_t offOf(uint32_t seq) const { return (uint32_t)(seq - base()); }
	uint32_t txBase() const { return isnToe + 1; }
};

static inline uint8_t rxByte(uint32_t seed, int idx, uint64_t off) { return genByte(seed, (uint32_t)idx, off); }
static inline uint8_t txByte(uint32_t seed, int idx, uint64_t off) { return genByte(seed ^ 0x5EED, 100 + (uint32_t)idx, off); }

struct Tb
{
	uint32_t seed;
	// toe_top ports
	hls::stream<TopWord> ipRxData, rxRdData, txRdData, ipTxData, rxWrData, txWrData, txDataReq, rxDataRsp;
	hls::stream<mmStatus> rxWrSts, txWrSts;
	hls::stream<mmCmd> rxWrCmd, rxRdCmd, txWrCmd, txRdCmd;
	hls::stream<rtlSessionLookupReply> lupRsp;
	hls::stream<rtlSessionUpdateReply> updRsp;
	hls::stream<rtlSessionLookupRequest> lupReq;
	hls::stream<rtlSessionUpdateRequest> updReq;
	hls::stream<ap_uint<16> > listenReq, closeReq, rdRspMeta;
	hls::stream<appReadRequest> rdReq;
	hls::stream<ipTuple> openReq;
	hls::stream<appTxMeta> txMeta;
	hls::stream<bool> listenRsp;
	hls::stream<appNotification> notif;
	hls::stream<openStatus> openRsp;
	hls::stream<appTxRsp> txRsp;
	ap_uint<16> sessCount;

	MemModel rxMem, txMem;
	std::map<threeTupleInternal, ap_uint<16> > cam;

	std::vector<Sess> s;
	std::map<int, int> sid2idx;

	// peer
	std::deque<TopWord> injQ;
	std::vector<uint8_t> outPkt;
	size_t rr = 0;
	bool winIdleCheck = false;
	uint64_t nWinChecks = 0;

	// application
	int pendingOpen = -1;
	int listenOk = -1;
	bool appPaused = false;
	std::function<bool(int&, uint32_t&)> pickRead;
	size_t maxOutstanding = 2;
	struct RdReq
	{
		int idx;
		uint32_t len;
		uint64_t off;
	};
	std::deque<RdReq> rdQ;
	bool respActive = false;
	RdReq resp;
	uint32_t respGot = 0;
	uint64_t lastReadIssue = 0, nReads = 0;
	uint64_t covRdWrap = 0, covRdWrapUnaligned = 0, covRd64k = 0, covRd64kUnaligned = 0;
	// application transmit
	int txIdx = -1;
	bool txWaitRsp = false;
	uint32_t txChunk = 0;
	uint64_t txTotal = 0, txRetryAt = 0, nTxNoSpace = 0;
	std::function<uint32_t()> txChunkFn;

	Tb(uint32_t sd, int lat, int stall)
		: seed(sd), rxMem("rxmem", lat, lat, stall, sd * 3 + 1), txMem("txmem", lat, lat, stall, sd * 5 + 2)
	{
	}

	Sess& add(const Sess& c)
	{
		s.push_back(c);
		s.back().idx = (int)s.size() - 1;
		return s.back();
	}

	// --------------------------------------------------------------------------------------------
	void tick()
	{
		toe_top(ipRxData, rxWrSts, txWrSts, rxRdData, txRdData, ipTxData, rxWrCmd, rxRdCmd, txWrCmd, txRdCmd, rxWrData,
				txWrData, lupRsp, updRsp, lupReq, updReq, listenReq, rdReq, openReq, closeReq, txMeta, txDataReq,
				listenRsp, notif, rdRspMeta, rxDataRsp, openRsp, txRsp, ap_uint<32>(0x0100000A) /* 10.0.0.1 */,
				sessCount);
		camStep();
		rxMem.step(rxWrCmd, rxWrData, rxWrSts, rxRdCmd, rxRdData);
		txMem.step(txWrCmd, txWrData, txWrSts, txRdCmd, txRdData);
		peerStep();
		appStep();
		g_cycle++;
	}

	bool run(uint64_t n)
	{
		for (uint64_t i = 0; i < n && !g_failed; i++)
			tick();
		return !g_failed;
	}

	bool runUntil(const std::function<bool()>& pred, uint64_t maxCycles, const char* what)
	{
		for (uint64_t i = 0; i < maxCycles; i++)
		{
			if (pred())
				return true;
			tick();
			if (g_failed)
				return false;
		}
		if (pred())
			return true;
		tbFail("timeout after %llu cycles waiting for: %s", (unsigned long long)maxCycles, what);
		return false;
	}

	// --------------------------------------------------------------------------------------------
	// session-lookup CAM (as in the original toe_tb)
	void camStep()
	{
		if (!lupReq.empty())
		{
			rtlSessionLookupRequest q = lupReq.read();
			std::map<threeTupleInternal, ap_uint<16> >::const_iterator it = cam.find(q.key);
			if (it != cam.end())
				lupRsp.write(rtlSessionLookupReply(true, it->second, q.source));
			else
				lupRsp.write(rtlSessionLookupReply(false, q.source));
		}
		if (!updReq.empty())
		{
			rtlSessionUpdateRequest u = updReq.read();
			if (u.op == INSERT)
			{
				cam[u.key] = u.value;
				updRsp.write(rtlSessionUpdateReply(u.value, INSERT, u.source));
			}
			else
			{
				cam.erase(u.key);
				updRsp.write(rtlSessionUpdateReply(u.value, DELETE, u.source));
			}
		}
	}

	// --------------------------------------------------------------------------------------------
	// peer
	void enqueue(const std::vector<uint8_t>& b)
	{
		for (size_t i = 0; i < b.size(); i += WBYTES)
		{
			int n = (int)std::min((size_t)WBYTES, b.size() - i);
			injQ.push_back(packWord(b.data() + i, n, i + n == b.size()));
		}
	}

	uint16_t peerWin(const Sess& c) const { return 0xFFFF; }

	void sendSynAck(Sess& c)
	{
		std::vector<uint8_t> o;
		o.push_back(2);
		o.push_back(4);
		o.push_back(c.peerMss >> 8);
		o.push_back(c.peerMss & 0xFF);
		if (c.ws)
		{
			o.push_back(1);
			o.push_back(3);
			o.push_back(3);
			o.push_back((uint8_t)c.peerShift);
		}
		enqueue(buildTcp(SRV_IP, TOE_IP, SRV_PORT, c.toePort, c.isnPeer, c.isnToe + 1, F_SYN | F_ACK, 0xFFFF, o, NULL, 0));
	}

	void sendSyn(Sess& c) // passive open on the TOE side: we connect to c.listenPort
	{
		std::vector<uint8_t> o;
		o.push_back(2);
		o.push_back(4);
		o.push_back(c.peerMss >> 8);
		o.push_back(c.peerMss & 0xFF);
		if (c.ws)
		{
			o.push_back(1);
			o.push_back(3);
			o.push_back(3);
			o.push_back((uint8_t)c.peerShift);
		}
		c.toePort = c.listenPort;
		enqueue(buildTcp(SRV_IP, TOE_IP, SRV_PORT, c.listenPort, c.isnPeer, 0, F_SYN, 0xFFFF, o, NULL, 0));
	}

	void sendData(Sess& c, uint32_t seq, uint32_t len)
	{
		std::vector<uint8_t> pay(len);
		uint64_t off = c.offOf(seq);
		for (uint32_t i = 0; i < len; i++)
			pay[i] = rxByte(seed, c.idx, off + i);
		enqueue(buildTcp(SRV_IP, TOE_IP, SRV_PORT, c.toePort, seq, c.rcvNxt, F_ACK | F_PSH, peerWin(c),
						 std::vector<uint8_t>(), pay.data(), len));
		if (seqDiff(seq + len, c.maxSent) > 0)
			c.maxSent = seq + len;
		c.nSegsSent++;
	}

	// scripted segment by stream offset
	void sendOff(Sess& c, uint64_t off, uint32_t len) { sendData(c, c.base() + (uint32_t)off, len); }

	void sendBare(Sess& c, uint32_t seq) // zero-length ACK segment with an arbitrary sequence number
	{
		enqueue(buildTcp(SRV_IP, TOE_IP, SRV_PORT, c.toePort, seq, c.rcvNxt, F_ACK, peerWin(c), std::vector<uint8_t>(),
						 NULL, 0));
	}
	void sendProbe(Sess& c)
	{
		sendBare(c, c.sndUna - 1); // Linux tcp_xmit_probe_skb: "use a previous sequence"
		c.nProbe++;
		c.lastProbe = g_cycle;
	}

	int findByPort(uint16_t port)
	{
		for (size_t i = 0; i < s.size(); i++)
			if (s[i].synSeen && s[i].toePort == port)
				return (int)i;
		return -1;
	}

	void onAck(Sess& c, const TcpPkt& p)
	{
		if (seqDiff(p.ack, c.maxSent) > 0)
		{
			tbFail("session %d: TOE acks 0x%08x beyond the highest byte sent 0x%08x", c.idx, p.ack, c.maxSent);
			return;
		}
		int32_t d = seqDiff(p.ack, c.sndUna);
		if (d < 0)
			return; // stale
		if (d > 0)
		{
			c.sndUna = p.ack;
			c.lastProgress = g_cycle;
			if (seqLt(c.sndNxt, c.sndUna))
				c.sndNxt = c.sndUna;
		}
		else if (p.pay.empty())
			c.nDupAcks++;
		int sh = c.ws ? c.toeShift : 0;
		uint64_t wbytes = (uint64_t)p.win << sh;
		uint32_t right = p.ack + (uint32_t)wbytes;
		c.nAcks++;
		c.lastAck = p.ack;
		c.lastWin = p.win;
		uint64_t ackOff = c.offOf(p.ack);
		// never promise more than the ring can hold given what the app has asked for so far
		if (ackOff + wbytes > c.requested + RING - 1)
		{
			tbFail("session %d: window reaches stream offset %llu but the app has only released up to %llu + %u",
				   c.idx, (unsigned long long)(ackOff + wbytes), (unsigned long long)c.requested, RING - 1);
			return;
		}
		if (c.haveWnd && seqDiff(right, c.maxRight) < -(int32_t)(1u << sh))
		{
			tbFail("session %d: window right edge moved back by %d bytes (ack 0x%08x win %u)", c.idx,
				   -seqDiff(right, c.maxRight), p.ack, p.win);
			return;
		}
		if (!c.haveWnd || seqDiff(right, c.maxRight) > 0)
			c.maxRight = right;
		c.wndRight = right;
		c.haveWnd = true;
		// exact check while the application is idle: window == ring free space, rounded down to the scale
		if (winIdleCheck && !respActive && rdQ.empty() && g_cycle > lastReadIssue + 500 && ackOff >= c.requested)
		{
			uint64_t unread = ackOff - c.requested;
			uint64_t freeb = (uint64_t)RING - 1 - unread;
			uint64_t expField = c.ws ? (freeb >> sh) : (freeb > 0xFFFF ? 0xFFFF : freeb);
			if (p.win != expField)
			{
				tbFail("session %d: advertised window field %u (shift %d) but the ring has %llu bytes free: expected %llu",
					   c.idx, p.win, sh, (unsigned long long)freeb, (unsigned long long)expField);
				return;
			}
			nWinChecks++;
		}
	}

	void onToeData(Sess& c, const TcpPkt& p)
	{
		uint32_t len = (uint32_t)p.pay.size();
		c.nTxSegs++;
		uint64_t off = (uint32_t)(p.seq - c.txBase());
		if (off + len > c.txQueued)
		{
			tbFail("session %d: TOE sends stream bytes %llu..%llu, the app gave it only %llu", c.idx,
				   (unsigned long long)off, (unsigned long long)(off + len), (unsigned long long)c.txQueued);
			return;
		}
		for (uint32_t i = 0; i < len; i++)
			if (p.pay[i] != txByte(seed, c.idx, off + i))
			{
				tbFail("session %d: TOE tx byte %llu is 0x%02x, expected 0x%02x (segment seq 0x%08x len %u)", c.idx,
					   (unsigned long long)(off + i), p.pay[i], txByte(seed, c.idx, off + i), p.seq, len);
				return;
			}
		bool drop = c.dropTx && c.dropTx(p.seq, len);
		if (drop)
			c.nTxDropped++;
		else if (seqDiff(p.seq, c.rcvNxt) <= 0 && seqDiff(p.seq + len, c.rcvNxt) > 0)
		{
			c.txRecv += (uint32_t)(p.seq + len - c.rcvNxt);
			c.rcvNxt = p.seq + len;
		}
		sendBare(c, c.sndNxt); // (dup) ACK
	}

	void onToePkt(const std::vector<uint8_t>& bytes)
	{
		TcpPkt p = parseTcp(bytes, false);
		if (!p.ok)
		{
			tbFail("TOE emitted a bad packet: %s", p.err.c_str());
			return;
		}
		if (p.sip != TOE_IP || p.dip != SRV_IP || p.dp != SRV_PORT)
		{
			tbFail("TOE packet with unexpected addressing %08x -> %08x:%u", p.sip, p.dip, p.dp);
			return;
		}
		if (p.flags & F_RST)
		{
			tbFail("TOE sent RST (port %u seq 0x%08x)", p.sp, p.seq);
			return;
		}
		if ((p.flags & F_SYN) && (p.flags & F_ACK))
		{
			for (size_t i = 0; i < s.size(); i++)
			{
				Sess& c = s[i];
				if (!c.passive || c.listenPort != p.sp)
					continue;
				if (p.ack != c.isnPeer + 1)
				{
					tbFail("session %d: TOE SYN-ACK acks 0x%08x, expected 0x%08x", c.idx, p.ack, c.isnPeer + 1);
					return;
				}
				if (c.ws && p.ws != (int)WINDOW_SCALE_BITS)
					tbFail("TOE SYN-ACK offers window scale %d, expected %u", p.ws, WINDOW_SCALE_BITS);
				if (!c.ws && p.ws >= 0)
					tbFail("TOE SYN-ACK offers window scaling to a peer that did not");
				c.synSeen = true;
				c.isnToe = p.seq;
				c.toeShift = c.ws ? p.ws : 0;
				c.rcvNxt = p.seq + 1;
				c.sndUna = c.sndNxt = c.maxSent = c.maxRight = c.base();
				c.wndRight = c.base() + p.win; // a SYN-ACK's window is never scaled
				c.haveWnd = true;
				c.established = true;
				c.lastProgress = g_cycle;
				sendBare(c, c.base());
				return;
			}
			tbFail("unexpected SYN-ACK from TOE port %u", p.sp);
			return;
		}
		int idx = findByPort(p.sp);
		if ((p.flags & F_SYN) && !(p.flags & F_ACK))
		{
			if (idx < 0)
			{
				idx = pendingOpen;
				if (idx < 0 || s[idx].synSeen)
				{
					tbFail("unexpected SYN from TOE port %u", p.sp);
					return;
				}
			}
			Sess& c = s[idx];
			c.synSeen = true;
			c.toePort = p.sp;
			c.isnToe = p.seq;
			c.toeShift = p.ws;
			c.rcvNxt = p.seq + 1;
			if (p.ws != (int)WINDOW_SCALE_BITS)
				tbFail("TOE SYN offers window scale %d, expected %u", p.ws, WINDOW_SCALE_BITS);
			if (p.mss != MSS)
				tbFail("TOE SYN offers MSS %d, expected %u", p.mss, MSS);
			sendSynAck(c);
			return;
		}
		if (idx < 0)
		{
			tbFail("TOE packet for unknown port %u", p.sp);
			return;
		}
		Sess& c = s[idx];
		c.nToePkts++;
		if (!(p.flags & F_ACK) || (p.flags & (F_SYN | F_FIN)))
		{
			tbFail("session %d: unexpected TOE flags 0x%02x", c.idx, p.flags);
			return;
		}
		if (!c.established)
		{
			if (p.ack != c.base())
			{
				tbFail("session %d: handshake ACK acks 0x%08x, expected 0x%08x", c.idx, p.ack, c.base());
				return;
			}
			c.established = true;
			c.sndUna = c.sndNxt = c.maxSent = c.maxRight = c.base();
			c.lastProgress = g_cycle;
		}
		onAck(c, p);
		if (!g_failed && !p.pay.empty())
			onToeData(c, p);
	}

	bool canAutoSend(const Sess& c) const
	{
		if (!c.autoSend || !c.established || !c.haveWnd)
			return false;
		uint64_t off = c.offOf(c.sndNxt);
		return off < std::min(c.rxLen, c.autoLimit) && seqLt(c.sndNxt, c.wndRight);
	}

	void peerStep()
	{
		while (!ipTxData.empty())
		{
			TopWord w = ipTxData.read();
			uint8_t b[WBYTES];
			bool contig;
			int n = unpackWord(w, b, contig);
			if (!contig)
			{
				tbFail("TOE tx stream: keep not contiguous");
				return;
			}
			outPkt.insert(outPkt.end(), b, b + n);
			if (w.last)
			{
				onToePkt(outPkt);
				outPkt.clear();
				if (g_failed)
					return;
			}
		}
		// retransmission timeout and zero-window probes
		for (size_t i = 0; i < s.size(); i++)
		{
			Sess& c = s[i];
			if (!c.autoSend || !c.established)
				continue;
			if (c.sndUna != c.sndNxt && g_cycle > c.lastProgress + c.rto)
			{
				c.sndNxt = c.sndUna; // go-back-N
				c.lastProgress = g_cycle;
				c.nRto++;
			}
			bool pending = c.offOf(c.sndNxt) < std::min(c.rxLen, c.autoLimit);
			bool closed = c.haveWnd && !seqLt(c.sndNxt, c.wndRight);
			if (pending && closed && g_cycle > c.lastProgress + c.probeInt && g_cycle > c.lastProbe + c.probeInt)
				sendProbe(c);
		}
		// one new segment per cycle while the wire is not backed up
		if (injQ.size() < 48)
		{
			for (size_t k = 0; k < s.size(); k++)
			{
				Sess& c = s[(rr + k) % s.size()];
				if (!canAutoSend(c))
					continue;
				uint64_t off = c.offOf(c.sndNxt);
				uint64_t len = c.segSizes[c.segIdx % c.segSizes.size()];
				len = std::min(len, std::min(c.rxLen, c.autoLimit) - off);
				len = std::min(len, (uint64_t)(uint32_t)(c.wndRight - c.sndNxt));
				if (c.sndUna == c.sndNxt)
					c.lastProgress = g_cycle; // (re)start the timer
				sendData(c, c.sndNxt, (uint32_t)len);
				c.sndNxt += (uint32_t)len;
				c.segIdx++;
				rr = (rr + k + 1) % s.size();
				break;
			}
		}
		if (!injQ.empty())
		{
			ipRxData.write(injQ.front());
			injQ.pop_front();
		}
	}

	// --------------------------------------------------------------------------------------------
	// application
	void issueRead(int idx, uint32_t len)
	{
		Sess& c = s[idx];
		uint64_t avail = c.notified - c.requested;
		if (len == 0 || len > 0xFFFF || len > avail)
		{
			tbFail("testbench bug: read of %u bytes on session %d with %llu available", len, idx,
				   (unsigned long long)avail);
			return;
		}
		uint32_t pos = (c.base() + (uint32_t)c.requested) & (RING - 1);
		if (pos + len > RING)
		{
			covRdWrap++;
			if ((RING - pos) % WBYTES)
				covRdWrapUnaligned++;
		}
		else if ((pos & 0xFFFF) + len > 0x10000)
		{
			covRd64k++;
			if ((0x10000 - (pos & 0xFFFF)) % WBYTES)
				covRd64kUnaligned++;
		}
		rdReq.write(appReadRequest(c.sid, len));
		RdReq r;
		r.idx = idx;
		r.len = len;
		r.off = c.requested;
		rdQ.push_back(r);
		c.requested += len;
		lastReadIssue = g_cycle;
		nReads++;
	}

	void appStep()
	{
		while (!openRsp.empty())
		{
			openStatus o = openRsp.read();
			if (pendingOpen < 0 || !o.success)
			{
				tbFail("unexpected/failed open response (session id %u, success %u)", (unsigned)o.sessionID,
					   (unsigned)o.success);
				return;
			}
			Sess& c = s[pendingOpen];
			c.sid = o.sessionID;
			c.opened = true;
			sid2idx[c.sid] = pendingOpen;
		}
		while (!listenRsp.empty())
			listenOk = listenRsp.read() ? 1 : 0;
		while (!notif.empty())
		{
			appNotification n = notif.read();
			if (n.opened)
			{
				// passive open: the "opened" notification (length 0) introduces the session id
				int idx = -1;
				for (size_t i = 0; i < s.size(); i++)
					if (s[i].passive && !s[i].opened)
						idx = (int)i;
				if (idx < 0 || n.length != 0 || n.closed || sid2idx.count((int)n.sessionID))
				{
					tbFail("unexpected opened notification (session %u, length %u)", (unsigned)n.sessionID,
						   (unsigned)n.length);
					return;
				}
				s[idx].sid = n.sessionID;
				s[idx].opened = true;
				sid2idx[s[idx].sid] = idx;
				continue;
			}
			std::map<int, int>::iterator it = sid2idx.find((int)n.sessionID);
			if (it == sid2idx.end())
			{
				tbFail("notification for unknown session %u", (unsigned)n.sessionID);
				return;
			}
			Sess& c = s[it->second];
			c.notified += n.length;
			if (n.closed)
				c.closedNotif = true;
			if (c.notified > c.rxLen)
			{
				tbFail("session %d: %llu bytes notified, the peer only has %llu", c.idx,
					   (unsigned long long)c.notified, (unsigned long long)c.rxLen);
				return;
			}
		}
		// read responses
		for (;;)
		{
			if (!respActive)
			{
				if (rdRspMeta.empty())
					break;
				ap_uint<16> sid = rdRspMeta.read();
				if (rdQ.empty())
				{
					tbFail("read response without a request");
					return;
				}
				resp = rdQ.front();
				rdQ.pop_front();
				if ((int)sid != s[resp.idx].sid)
				{
					tbFail("read response for session %u, expected %d", (unsigned)sid, s[resp.idx].sid);
					return;
				}
				respActive = true;
				respGot = 0;
			}
			if (rxDataRsp.empty())
				break;
			TopWord w = rxDataRsp.read();
			uint8_t b[WBYTES];
			bool contig;
			int n = unpackWord(w, b, contig);
			Sess& c = s[resp.idx];
			if (!contig || n == 0 || (uint32_t)n > resp.len - respGot || ((uint32_t)n < resp.len - respGot && n != WBYTES))
			{
				tbFail("session %d: malformed read beat (keep 0x%016llx, %u of %u bytes received)", c.idx,
					   (unsigned long long)w.keep.to_uint64(), respGot, resp.len);
				return;
			}
			for (int i = 0; i < n; i++)
			{
				uint64_t off = resp.off + respGot + i;
				if (b[i] != rxByte(seed, c.idx, off))
				{
					uint32_t pos = (c.base() + (uint32_t)off) & (RING - 1);
					tbFail("session %d: byte at stream offset %llu (ring 0x%05x) is 0x%02x, expected 0x%02x "
						   "(read of %u at offset %llu, byte %u)",
						   c.idx, (unsigned long long)off, pos, b[i], rxByte(seed, c.idx, off), resp.len,
						   (unsigned long long)resp.off, respGot + i);
					return;
				}
			}
			respGot += n;
			bool lastExp = (respGot == resp.len);
			if ((w.last == 1) != lastExp)
			{
				tbFail("session %d: read response tlast=%d with %u of %u bytes", c.idx, (int)w.last, respGot, resp.len);
				return;
			}
			if (lastExp)
			{
				c.verified += resp.len;
				respActive = false;
			}
		}
		// new reads
		if (!appPaused && pickRead && rdQ.size() < maxOutstanding)
		{
			int idx;
			uint32_t len;
			if (pickRead(idx, len))
				issueRead(idx, len);
		}
		// transmit
		if (txIdx >= 0)
		{
			Sess& c = s[txIdx];
			if (!txWaitRsp && c.txQueued < txTotal && g_cycle >= txRetryAt)
			{
				txChunk = txChunkFn();
				txChunk = (uint32_t)std::min((uint64_t)txChunk, txTotal - c.txQueued);
				txMeta.write(appTxMeta(c.sid, txChunk));
				txWaitRsp = true;
			}
			if (txWaitRsp && !txRsp.empty())
			{
				appTxRsp r = txRsp.read();
				txWaitRsp = false;
				if (r.error == 0)
				{
					std::vector<uint8_t> b(txChunk);
					for (uint32_t i = 0; i < txChunk; i++)
						b[i] = txByte(seed, c.idx, c.txQueued + i);
					for (uint32_t i = 0; i < txChunk; i += WBYTES)
					{
						int n = (int)std::min((uint32_t)WBYTES, txChunk - i);
						txDataReq.write(packWord(b.data() + i, n, i + n == txChunk));
					}
					c.txQueued += txChunk;
				}
				else
				{
					txRetryAt = g_cycle + 200;
					nTxNoSpace++;
				}
			}
		}
	}

	bool openSession(int idx)
	{
		pendingOpen = idx;
		ipTuple t;
		t.ip_address = SRV_IP;
		t.ip_port = SRV_PORT;
		openReq.write(t);
		bool ok = runUntil([&]() { return s[idx].opened && s[idx].established; }, 20000, "connection established");
		pendingOpen = -1;
		if (ok)
			tbInfo("session %d open: sid %d, TOE port %u, TOE ISN 0x%08x, peer ISN 0x%08x, ws %d/%d", idx, s[idx].sid,
				   s[idx].toePort, s[idx].isnToe, s[idx].isnPeer, s[idx].ws ? s[idx].peerShift : -1, s[idx].toeShift);
		return ok;
	}

	bool openAll()
	{
		for (size_t i = 0; i < s.size(); i++)
			if (!openSession((int)i))
				return false;
		return true;
	}

	bool allDelivered() const
	{
		for (size_t i = 0; i < s.size(); i++)
			if (s[i].verified != s[i].rxLen)
				return false;
		return true;
	}

	void summary() const
	{
		for (size_t i = 0; i < s.size(); i++)
		{
			const Sess& c = s[i];
			tbInfo("session %d: rx %llu/%llu verified, notified %llu; segs sent %llu, RTOs %llu, probes %llu, ACKs %llu "
				   "(dup %llu); tx %llu queued %llu acked, tx segs %llu dropped %llu",
				   c.idx, (unsigned long long)c.verified, (unsigned long long)c.rxLen, (unsigned long long)c.notified,
				   (unsigned long long)c.nSegsSent, (unsigned long long)c.nRto, (unsigned long long)c.nProbe,
				   (unsigned long long)c.nAcks, (unsigned long long)c.nDupAcks, (unsigned long long)c.txQueued,
				   (unsigned long long)c.txRecv, (unsigned long long)c.nTxSegs, (unsigned long long)c.nTxDropped);
		}
		tbInfo("reads %llu (wrap %llu, wrap with unaligned first part %llu, 64KiB-crossing %llu / unaligned %llu); "
			   "window checks %llu",
			   (unsigned long long)nReads, (unsigned long long)covRdWrap, (unsigned long long)covRdWrapUnaligned,
			   (unsigned long long)covRd64k, (unsigned long long)covRd64kUnaligned, (unsigned long long)nWinChecks);
		tbInfo("rxmem: %llu write cmds (%llu ending unaligned at the ring end, %llu starting at 0), %llu read cmds "
			   "(%llu ending at the ring end, %llu starting at 0); txmem: %llu write, %llu read cmds (%llu ending at "
			   "the ring end, %llu starting at 0)",
			   (unsigned long long)rxMem.nWrCmd, (unsigned long long)rxMem.nWrEndAtRingEndUnaligned,
			   (unsigned long long)rxMem.nWrStartAtZero, (unsigned long long)rxMem.nRdCmd,
			   (unsigned long long)rxMem.nRdEndAtRingEnd, (unsigned long long)rxMem.nRdStartAtZero,
			   (unsigned long long)txMem.nWrCmd, (unsigned long long)txMem.nRdCmd,
			   (unsigned long long)txMem.nRdEndAtRingEnd, (unsigned long long)txMem.nRdStartAtZero);
	}
};

// read policy: whatever is available, round-robin over `sessions`, lengths random in [lo, hi]
static std::function<bool(int&, uint32_t&)> greedyReader(Tb& tb, std::vector<int> sessions, uint32_t lo, uint32_t hi,
														  uint32_t seed)
{
	std::shared_ptr<Rng> r(new Rng(seed));
	std::shared_ptr<size_t> next(new size_t(0));
	return [&tb, sessions, lo, hi, r, next](int& idx, uint32_t& len) -> bool {
		for (size_t k = 0; k < sessions.size(); k++)
		{
			int i = sessions[(*next + k) % sessions.size()];
			Sess& c = tb.s[i];
			uint64_t avail = c.notified - c.requested;
			if (avail == 0)
				continue;
			uint64_t want = r->range(lo, hi);
			idx = i;
			len = (uint32_t)std::min(avail, want);
			*next = (*next + k + 1) % sessions.size();
			return true;
		}
		return false;
	};
}

static bool expect(bool cond, const char* fmt, ...)
{
	if (cond || g_failed)
		return cond;
	char buf[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	tbFail("%s", buf);
	return false;
}

// wait until the TOE has acknowledged up to stream offset `off` of session c
static bool waitAcked(Tb& tb, Sess& c, uint64_t off, uint64_t budget, const char* what)
{
	return tb.runUntil([&]() { return c.offOf(c.sndUna) >= off && seqDiff(c.sndUna, c.base()) >= 0; }, budget, what);
}

// ================================================================================================
// c1: one session, > 2 MiB in order, reads of odd lengths that cross 64 KiB boundaries and the 1 MiB
// ring end with unaligned first parts (fixes 1, 2); segments of odd sizes so writes split unaligned.
// ================================================================================================
static bool case_c1(Tb& tb)
{
	Sess cfg;
	cfg.isnPeer = 0x2468ACE1; // stream starts at ring offset 0x8ACE2
	cfg.rxLen = 3 * 1024 * 1024 + 12345;
	cfg.segSizes = {1448, 4096, 1000, 3, 777, 4096, 2049, 65, 1448, 63};
	tb.add(cfg);
	if (!tb.openAll())
		return false;
	Sess& c = tb.s[0];
	static const uint32_t lens[] = {1, 7, 63, 64, 65, 129, 511, 1023, 1500, 4097, 8191, 12345, 30001, 65535, 777};
	static const uint32_t firstParts[] = {1, 127, 4161};
	std::shared_ptr<size_t> li(new size_t(0));
	std::shared_ptr<int> wrapK(new int(0));
	tb.maxOutstanding = 3;
	tb.pickRead = [&tb, li, wrapK](int& idx, uint32_t& len) -> bool {
		Sess& c = tb.s[0];
		uint64_t remaining = c.rxLen - c.requested;
		if (!remaining)
			return false;
		uint32_t pos = (c.base() + (uint32_t)c.requested) & (RING - 1);
		uint32_t d = RING - pos;
		uint32_t F = firstParts[std::min(*wrapK, 2)];
		uint64_t want = lens[*li % (sizeof(lens) / sizeof(lens[0]))];
		bool crossing = false;
		if (d <= 70000)
		{
			if (d > F)
				want = d - F; // land F bytes before the ring end...
			else if (d == F)
			{
				want = F + 1 + (*li * 7919) % 20000; // ...then cross it with a first part of F bytes
				crossing = true;
			}
		}
		want = std::min(want, (uint64_t)0xFFFF);
		want = std::min(want, remaining);
		if (c.notified - c.requested < want)
			return false;
		idx = 0;
		len = (uint32_t)want;
		(*li)++;
		if (crossing)
			(*wrapK)++;
		return true;
	};
	c.autoSend = true;
	if (!tb.runUntil([&]() { return tb.allDelivered(); }, 6000000, "all c1 data read back"))
		return false;
	tb.summary();
	return expect(tb.covRdWrapUnaligned >= 2, "coverage: only %llu ring-end reads with an unaligned first part",
				  (unsigned long long)tb.covRdWrapUnaligned) &&
		   expect(tb.covRd64kUnaligned >= 10, "coverage: only %llu unaligned 64 KiB-crossing reads",
				  (unsigned long long)tb.covRd64kUnaligned) &&
		   expect(tb.rxMem.nWrEndAtRingEndUnaligned >= 1, "coverage: no write split unaligned at the ring end");
}

// ================================================================================================
// c2: four sessions interleaved on the wire; the app reads session 3 to the end first, then the
// others in random order with random lengths (any-order demultiplexing; full rings, zero windows,
// probes).
// ================================================================================================
static bool case_c2(Tb& tb)
{
	const uint32_t isns[4] = {0x10000001, 0x7FFFFFF0, 0xA5A5A5A5, 0x00000100};
	const std::vector<uint32_t> segs[4] = {{1448}, {4096}, {1000, 3000}, {536, 1448, 4096}};
	for (int i = 0; i < 4; i++)
	{
		Sess cfg;
		cfg.isnPeer = isns[i];
		cfg.rxLen = 1310720 + 1111 * i;
		cfg.segSizes = segs[i];
		tb.add(cfg);
	}
	if (!tb.openAll())
		return false;
	std::shared_ptr<Rng> r(new Rng(tb.seed));
	tb.maxOutstanding = 2;
	tb.pickRead = [&tb, r](int& idx, uint32_t& len) -> bool {
		Sess& s3 = tb.s[3];
		if (s3.requested < s3.rxLen)
		{
			uint64_t avail = s3.notified - s3.requested;
			if (!avail)
				return false;
			idx = 3;
			len = (uint32_t)std::min(avail, (uint64_t)r->range(1, 65535));
			return true;
		}
		static const int order[3] = {1, 0, 2};
		int start = r->range(0, 2);
		for (int k = 0; k < 3; k++)
		{
			int i = order[(start + k) % 3];
			Sess& c = tb.s[i];
			uint64_t avail = c.notified - c.requested;
			if (!avail)
				continue;
			uint32_t want = (r->next() & 3) ? r->range(4096, 65535) : r->range(1, 4096);
			idx = i;
			len = (uint32_t)std::min(avail, (uint64_t)want);
			return true;
		}
		return false;
	};
	for (int i = 0; i < 4; i++)
		tb.s[i].autoSend = true;
	if (!tb.runUntil([&]() { return tb.s[3].verified == tb.s[3].rxLen; }, 4000000, "session 3 read to the end"))
		return false;
	for (int i = 0; i < 3; i++)
		if (!expect(tb.s[i].verified == 0, "session %d was read before session 3 finished", i))
			return false;
	if (!tb.runUntil([&]() { return tb.allDelivered(); }, 8000000, "all c2 data read back"))
		return false;
	tb.summary();
	return expect(tb.s[0].nProbe + tb.s[1].nProbe + tb.s[2].nProbe > 0, "coverage: no zero-window probe happened");
}

// ================================================================================================
// c3: out of order. A single gap with held data behind it, then a run of out-of-order data longer
// than 64 KiB (fix 5: only what ends within 0xFFFF of recvd is held; the rest is resent). A second
// session runs alongside to check the shared pipeline stays in sync.
// ================================================================================================
static bool case_c3(Tb& tb)
{
	Sess a;
	a.isnPeer = 0x55555555;
	a.rxLen = 400000;
	Sess b;
	b.isnPeer = 0x0BADF00D;
	b.rxLen = 300000;
	b.segSizes = {1448, 999};
	tb.add(a);
	tb.add(b);
	if (!tb.openAll())
		return false;
	Sess& A = tb.s[0];
	Sess& B = tb.s[1];
	tb.pickRead = greedyReader(tb, {0, 1}, 1, 40000, tb.seed);
	A.autoSend = B.autoSend = true;
	A.autoLimit = 20000;
	if (!waitAcked(tb, A, 20000, 200000, "A: first 20000 bytes acked"))
		return false;
	A.autoSend = false;
	const uint32_t L = 1448;
	// single gap: S0 missing, S1..S10 held
	uint64_t X = A.offOf(A.sndUna);
	for (int k = 1; k <= 10; k++)
		tb.sendOff(A, X + k * L, L);
	if (!tb.run(3000))
		return false;
	if (!expect(A.offOf(A.sndUna) == X, "A: ack moved to %llu while the gap at %llu was open",
				(unsigned long long)A.offOf(A.sndUna), (unsigned long long)X))
		return false;
	tb.sendOff(A, X, L);
	if (!waitAcked(tb, A, X + 11 * L, 4000, "A: ack jumps over the 10 held segments once the gap is filled"))
		return false;
	if (!expect(A.offOf(A.sndUna) == X + 11 * L, "A: ack %llu after filling, expected %llu",
				(unsigned long long)A.offOf(A.sndUna), (unsigned long long)(X + 11 * L)))
		return false;
	A.sndNxt = A.sndUna;
	// out-of-order run of 60 segments (86880 bytes) behind a gap
	uint64_t Y = A.offOf(A.sndUna);
	for (int k = 1; k <= 60; k++)
		tb.sendOff(A, Y + k * L, L);
	if (!tb.run(4000))
		return false;
	if (!expect(A.offOf(A.sndUna) == Y, "A: ack moved while the second gap was open"))
		return false;
	tb.sendOff(A, Y, L);
	uint64_t expectAck = Y + (uint64_t)(0xFFFF / L) * L; // held: segments ending within 0xFFFF of recvd
	if (!waitAcked(tb, A, expectAck, 4000, "A: ack covers the held part of the >64 KiB out-of-order run"))
		return false;
	if (!tb.run(3000))
		return false;
	if (!expect(A.offOf(A.sndUna) == expectAck, "A: ack %llu after the long run, expected exactly %llu",
				(unsigned long long)A.offOf(A.sndUna), (unsigned long long)expectAck))
		return false;
	A.sndNxt = A.sndUna;
	A.autoLimit = NO_LIMIT;
	A.autoSend = true;
	if (!tb.runUntil([&]() { return tb.allDelivered(); }, 4000000, "all c3 data read back"))
		return false;
	tb.summary();
	return true;
}

// ================================================================================================
// c4: retransmissions that overlap data already held behind a gap (Linux re-segments/merges on
// retransmit). Fix 3: every segment gets exactly one drop decision; the other session and the
// following segments must stay in sync.
// ================================================================================================
static bool case_c4(Tb& tb)
{
	Sess a;
	a.isnPeer = 0x31415926;
	a.rxLen = 300000;
	Sess b;
	b.isnPeer = 0x27182818;
	b.rxLen = 300000;
	b.segSizes = {1448, 4096, 17};
	tb.add(a);
	tb.add(b);
	if (!tb.openAll())
		return false;
	Sess& A = tb.s[0];
	Sess& B = tb.s[1];
	tb.pickRead = greedyReader(tb, {0, 1}, 1, 40000, tb.seed);
	A.autoSend = B.autoSend = true;
	A.autoLimit = 20000;
	if (!waitAcked(tb, A, 20000, 200000, "A: first 20000 bytes acked"))
		return false;
	A.autoSend = false;
	struct Step
	{
		const char* name;
		std::vector<std::pair<uint32_t, uint32_t> > held; // (offset, len) relative to recvd, sent first
		std::vector<std::pair<uint32_t, uint32_t> > fill; // then these, one by one...
		std::vector<uint32_t> ackAfter;                   // ...each expecting this ack (relative)
	};
	std::vector<Step> steps = {
		{"merged retransmit covering the gap and part of the held data", {{1000, 1448}, {2448, 1448}}, {{0, 2000}}, {3896}},
		{"merged retransmit reaching past head", {{1000, 1000}}, {{0, 3000}}, {3000}},
		{"exact fill (the old path)", {{1448, 1448}}, {{0, 1448}}, {2896}},
		{"partial fill, then an overlapping fill", {{3000, 1448}}, {{0, 1000}, {1000, 2500}}, {1000, 4448}},
		{"fill covering a small held block entirely", {{500, 500}}, {{0, 4000}}, {4000}},
	};
	for (size_t si = 0; si < steps.size(); si++)
	{
		const Step& st = steps[si];
		uint64_t R = A.offOf(A.sndUna);
		for (size_t k = 0; k < st.held.size(); k++)
			tb.sendOff(A, R + st.held[k].first, st.held[k].second);
		if (!tb.run(2000))
			return false;
		if (!expect(A.offOf(A.sndUna) == R, "A step '%s': ack moved while the gap was open", st.name))
			return false;
		for (size_t k = 0; k < st.fill.size(); k++)
		{
			tb.sendOff(A, R + st.fill[k].first, st.fill[k].second);
			uint64_t want = R + st.ackAfter[k];
			if (!waitAcked(tb, A, want, 4000, st.name))
				return false;
			if (!tb.run(500))
				return false;
			if (!expect(A.offOf(A.sndUna) == want, "A step '%s': ack %llu, expected %llu", st.name,
						(unsigned long long)A.offOf(A.sndUna), (unsigned long long)want))
				return false;
		}
		A.sndNxt = A.sndUna;
		// in order right after, to check nothing is off by a packet
		uint64_t R2 = A.offOf(A.sndUna);
		tb.sendOff(A, R2, 1448);
		if (!waitAcked(tb, A, R2 + 1448, 4000, "A: in-order segment right after the fill"))
			return false;
		A.sndNxt = A.sndUna;
		tbInfo("c4 step '%s' ok", st.name);
	}
	A.autoLimit = NO_LIMIT;
	A.autoSend = true;
	if (!tb.runUntil([&]() { return tb.allDelivered(); }, 4000000, "all c4 data read back"))
		return false;
	tb.summary();
	return true;
}

// ================================================================================================
// c5: sequence numbers wrap 2^32 in the middle of a gap; the held segments lie after the wrap
// (fix 4: signed comparisons).
// ================================================================================================
static bool case_c5(Tb& tb)
{
	Sess a;
	a.isnPeer = 0xFFFFFFFFu - 30000; // stream offset 30000 has sequence number 0
	a.rxLen = 300000;
	tb.add(a);
	if (!tb.openAll())
		return false;
	Sess& A = tb.s[0];
	tb.pickRead = greedyReader(tb, {0}, 1, 30000, tb.seed);
	A.autoSend = true;
	A.autoLimit = 27000;
	if (!waitAcked(tb, A, 27000, 200000, "first 27000 bytes acked"))
		return false;
	A.autoSend = false;
	if (!tb.run(500))
		return false;
	// gap [27000, 31000) straddles the wrap at 30000; held data after the wrap
	tb.sendOff(A, 31000, 1448);
	tb.sendOff(A, 32448, 1448);
	if (!tb.run(2000))
		return false;
	if (!expect(A.offOf(A.sndUna) == 27000, "ack moved while the gap was open"))
		return false;
	tb.sendOff(A, 27000, 4000);
	if (!waitAcked(tb, A, 33896, 4000, "ack covers the held data after the 2^32 wrap once the gap is filled"))
		return false;
	if (!expect(A.offOf(A.sndUna) == 33896, "ack %llu, expected 33896", (unsigned long long)A.offOf(A.sndUna)))
		return false;
	A.sndNxt = A.sndUna;
	A.autoLimit = NO_LIMIT;
	A.autoSend = true;
	if (!tb.runUntil([&]() { return tb.allDelivered(); }, 3000000, "all c5 data read back"))
		return false;
	tb.summary();
	return true;
}

// ================================================================================================
// c6: exact window fill with the application idle (fix 6), window == ring free space on every ACK
// while idle (fix 7: no bypass clamp), then the app drains and the peer's zero-window probe reopens
// the window (fix 9).
// ================================================================================================
static bool case_c6(Tb& tb)
{
	Sess a;
	a.isnPeer = 0x01020304;
	a.rxLen = (RING - 1) + 300000;
	a.segSizes = {4096, 1448, 333};
	tb.add(a);
	if (!tb.openAll())
		return false;
	Sess& A = tb.s[0];
	tb.appPaused = true;
	tb.pickRead = greedyReader(tb, {0}, 1, 65535, tb.seed);
	tb.winIdleCheck = true;
	A.autoSend = true;
	A.autoLimit = 15; // 15 unread bytes leave exactly RING - 16 free: a multiple of the window unit
	if (!waitAcked(tb, A, 15, 100000, "first 15 bytes acked"))
		return false;
	if (!tb.run(1000))
		return false;
	if (!expect(A.lastWin == 0xFFFF, "window field %u after 15 bytes, expected 0xFFFF (RING - 16 bytes)", A.lastWin))
		return false;
	A.autoLimit = RING - 1; // = 15 + the whole advertised window: the last segment fills the ring exactly
	if (!waitAcked(tb, A, RING - 1, 3000000, "exact window fill accepted while the app is idle"))
		return false;
	if (!tb.run(1000))
		return false;
	if (!expect(A.lastWin == 0, "window field %u with a full ring", A.lastWin))
		return false;
	tbInfo("c6: ring filled exactly (%u bytes unread), window 0", RING - 1);
	A.autoLimit = NO_LIMIT;
	uint64_t probes0 = A.nProbe;
	tb.appPaused = false;
	if (!tb.runUntil([&]() { return A.verified >= RING - 1; }, 3000000, "app drains the full ring"))
		return false;
	if (!tb.runUntil([&]() { return tb.allDelivered(); }, 3000000, "transfer resumes after the drain and completes"))
		return false;
	tb.summary();
	return expect(A.nProbe > probes0, "coverage: the window reopened without a probe") &&
		   expect(tb.nWinChecks >= 100, "coverage: only %llu exact window checks", (unsigned long long)tb.nWinChecks);
}

// ================================================================================================
// c6b: a peer without window scaling (fix 10): the advertised window is min(free space, 0xFFFF)
// ================================================================================================
static bool case_c6b(Tb& tb)
{
	Sess a;
	a.isnPeer = 0x0A0B0C0D;
	a.ws = false;
	a.rxLen = 200000;
	tb.add(a);
	if (!tb.openAll())
		return false;
	Sess& A = tb.s[0];
	tb.appPaused = true;
	tb.pickRead = greedyReader(tb, {0}, 1, 65535, tb.seed);
	tb.winIdleCheck = true;
	A.autoSend = true;
	if (!waitAcked(tb, A, A.rxLen, 2000000, "200000 bytes acked with the app idle"))
		return false;
	if (!tb.run(1000))
		return false;
	if (!expect(A.lastWin == 0xFFFF, "window field %u with ~830 KiB free, expected 0xFFFF", A.lastWin))
		return false;
	tb.appPaused = false;
	if (!tb.runUntil([&]() { return tb.allDelivered(); }, 2000000, "all c6b data read back"))
		return false;
	tb.summary();
	return expect(tb.nWinChecks >= 50, "coverage: only %llu exact window checks", (unsigned long long)tb.nWinChecks);
}

// ================================================================================================
// c7: a zero-length segment one below recvd (Linux's zero-window probe / keepalive) is answered
// with an ACK (fix 9); a pure ACK is not.
// ================================================================================================
static bool case_c7(Tb& tb)
{
	Sess a;
	a.isnPeer = 0x77777777;
	a.rxLen = 20000;
	tb.add(a);
	if (!tb.openAll())
		return false;
	Sess& A = tb.s[0];
	tb.pickRead = greedyReader(tb, {0}, 1, 30000, tb.seed);
	A.autoSend = true;
	if (!tb.runUntil([&]() { return tb.allDelivered(); }, 500000, "all c7 data read back"))
		return false;
	A.autoSend = false;
	if (!tb.run(3000))
		return false;
	uint64_t n0 = A.nToePkts;
	tb.sendProbe(A);
	if (!tb.runUntil([&]() { return A.nToePkts > n0; }, 4000, "an ACK for the zero-length probe at recvd - 1"))
		return false;
	if (!expect(A.lastAck == A.sndUna, "probe answered with ack 0x%08x, expected 0x%08x", A.lastAck, A.sndUna))
		return false;
	if (!tb.run(1000))
		return false;
	uint64_t n1 = A.nToePkts;
	tb.sendBare(A, A.sndNxt); // pure ACK at recvd
	if (!tb.run(4000))
		return false;
	if (!expect(A.nToePkts == n1, "the TOE answered a pure ACK (%llu packets)", (unsigned long long)(A.nToePkts - n1)))
		return false;
	tb.summary();
	return true;
}

// ================================================================================================
// c8: the app sends on session 1 (not session 0); the peer drops the segment that straddles the
// end of the tx ring once, so the TOE's retransmission reads it from card memory in two parts
// (fix 11: the second part comes from the same session's ring).
// ================================================================================================
static bool case_c8(Tb& tb)
{
	Sess a; // session 0: exists so that a read from "session 0" is detectably wrong
	a.isnPeer = 0x11111111;
	a.rxLen = 0;
	Sess b;
	b.isnPeer = 0x22222222;
	b.rxLen = 0;
	tb.add(a);
	tb.add(b);
	if (!tb.openAll())
		return false;
	Sess& B = tb.s[1];
	if (!expect(B.sid != 0, "session 1 got TOE session id 0"))
		return false;
	uint32_t p0 = B.txBase() & (RING - 1);
	std::shared_ptr<uint32_t> wrapSeq(new uint32_t(0));
	std::shared_ptr<int> afterWrap(new int(-1));
	std::shared_ptr<int> wrapSends(new int(0));
	std::shared_ptr<bool> dropped(new bool(false));
	tb.txIdx = 1;
	tb.txTotal = (uint64_t)(RING - p0) + 3 * 3001 + 4000;
	tb.txChunkFn = [&tb, p0, wrapSeq, afterWrap]() -> uint32_t {
		Sess& c = tb.s[1];
		uint32_t pos = (p0 + (uint32_t)c.txQueued) & (RING - 1);
		uint32_t dW = RING - pos;
		if (*afterWrap < 0 && dW < 3001)
		{
			*afterWrap = 0;
			*wrapSeq = c.txBase() + (uint32_t)c.txQueued;
			return dW + 1000; // one segment straddling the ring end: first part dW, second part 1000
		}
		return 3001;
	};
	B.dropTx = [wrapSeq, dropped, wrapSends, afterWrap](uint32_t seq, uint32_t len) -> bool {
		if (*afterWrap >= 0 && seq == *wrapSeq)
		{
			(*wrapSends)++;
			if (!*dropped)
			{
				*dropped = true;
				return true;
			}
		}
		return false;
	};
	tbInfo("c8: tx ring of session %d starts at offset 0x%05x, %llu bytes to send", B.sid, p0,
		   (unsigned long long)tb.txTotal);
	if (!tb.runUntil([&]() { return B.txRecv == tb.txTotal; }, 4000000, "peer received every byte the app sent"))
		return false;
	tb.summary();
	return expect(*dropped && *wrapSends >= 2, "coverage: the ring-straddling segment was not retransmitted (%d sends)",
				  *wrapSends) &&
		   expect(tb.txMem.nRdEndAtRingEnd >= 1 && tb.txMem.nRdStartAtZero >= 1,
				  "coverage: no split tx read (%llu ending at the ring end, %llu starting at 0)",
				  (unsigned long long)tb.txMem.nRdEndAtRingEnd, (unsigned long long)tb.txMem.nRdStartAtZero);
}

// ================================================================================================
// c9: passive open. The "opened" notification has no memory write behind it and must not wait for
// a write status (fix 8); the data notifications that follow must stay paired with their own writes.
// ================================================================================================
static bool case_c9(Tb& tb)
{
	Sess a;
	a.isnPeer = 0x0C0C0C0C;
	a.passive = true;
	a.listenPort = 8000;
	a.rxLen = 200000;
	a.segSizes = {1448, 4096, 100};
	tb.add(a);
	Sess& A = tb.s[0];
	tb.listenReq.write(A.listenPort);
	if (!tb.runUntil([&]() { return tb.listenOk >= 0; }, 2000, "listen response"))
		return false;
	if (!expect(tb.listenOk == 1, "listen on port %u refused", A.listenPort))
		return false;
	tb.sendSyn(A);
	if (!tb.runUntil([&]() { return A.established; }, 20000, "TOE answers the SYN with SYN-ACK"))
		return false;
	tb.pickRead = greedyReader(tb, {0}, 1, 30000, tb.seed);
	A.autoSend = true;
	if (!tb.runUntil([&]() { return A.opened; }, 20000, "the app gets the opened notification"))
		return false;
	tbInfo("c9: passive session open, sid %d, TOE ISN 0x%08x", A.sid, A.isnToe);
	if (!tb.runUntil([&]() { return tb.allDelivered(); }, 2000000, "all c9 data read back"))
		return false;
	tb.summary();
	return true;
}

// ================================================================================================
// c10: ring space comes back only when a read has completed (fix 12). The ring is full, the app
// issues one 64 KiB read that card memory serves late (3000-cycle read latency), and the peer
// probes every 60 cycles: if the window reopened when the read was ISSUED, the peer's next bytes
// would land on the region still waiting to be read.
// ================================================================================================
static bool case_c10(Tb& tb)
{
	Sess a;
	a.isnPeer = 0x5A5A5A5A;
	a.rxLen = (RING - 1) + 200000;
	a.segSizes = {4096};
	a.probeInt = 60;
	tb.add(a);
	if (!tb.openAll())
		return false;
	Sess& A = tb.s[0];
	tb.rxMem.latR = 3000;
	tb.appPaused = true;
	A.autoSend = true;
	if (!tb.runUntil([&]() { return A.haveWnd && A.lastWin == 0 && A.sndUna == A.sndNxt && A.offOf(A.sndUna) > RING - 64; },
					 3000000, "the ring fills up with the app idle"))
		return false;
	tbInfo("c10: ring full at stream offset %llu", (unsigned long long)A.offOf(A.sndUna));
	std::shared_ptr<int> phase(new int(0));
	std::shared_ptr<uint64_t> until(new uint64_t(0));
	std::function<bool(int&, uint32_t&)> greedy = greedyReader(tb, {0}, 1, 65535, tb.seed);
	tb.pickRead = [&tb, phase, until, greedy](int& idx, uint32_t& len) -> bool {
		if (*phase == 0)
		{
			*phase = 1;
			*until = g_cycle + 20000;
			idx = 0;
			len = 0xFFFF;
			return true;
		}
		if (*phase == 1 && g_cycle < *until)
			return false;
		*phase = 2;
		return greedy(idx, len);
	};
	tb.appPaused = false;
	if (!tb.runUntil([&]() { return tb.allDelivered(); }, 4000000, "all c10 data read back"))
		return false;
	tb.summary();
	return true;
}

// ================================================================================================
struct Case
{
	const char* name;
	bool (*fn)(Tb&);
	int lat, stall;
	const char* what;
};

static const Case kCases[] = {
	{"c1", case_c1, 80, 10, "in-order >2 MiB, odd reads across 64 KiB and the 1 MiB wrap (fixes 1, 2)"},
	{"c2", case_c2, 40, 5, "4 sessions interleaved, read in a different order (any-order demux)"},
	{"c3", case_c3, 40, 5, "out of order: single gap, then >64 KiB held run (fix 5)"},
	{"c4", case_c4, 40, 5, "overlapping retransmissions with a gap open (fix 3)"},
	{"c5", case_c5, 40, 5, "sequence wrap across 2^32 inside a gap (fix 4)"},
	{"c6", case_c6, 40, 5, "exact window fill, app idle; window == free space; probe reopens (fixes 6, 7, 9)"},
	{"c6b", case_c6b, 40, 5, "peer without window scaling: window saturates at 0xFFFF (fix 10)"},
	{"c7", case_c7, 40, 5, "zero-length probe at recvd-1 is ACKed, pure ACK is not (fix 9)"},
	{"c8", case_c8, 40, 5, "tx retransmission across the tx ring end, session != 0 (fix 11)"},
	{"c9", case_c9, 40, 5, "passive open: the opened notification passes the write-status delayer (fix 8)"},
	{"c10", case_c10, 40, 5, "full ring, slow read: space is released on read completion, not issue (fix 12)"},
};

int main(int argc, char** argv)
{
	std::string sel = argc > 1 ? argv[1] : "all";
	const char* ld = getenv("TOE_CSIM_LOGDIR");
	std::string logdir = ld && *ld ? ld : ".";
	mkdir(logdir.c_str(), 0755);
	std::vector<int> run;
	for (size_t i = 0; i < sizeof(kCases) / sizeof(kCases[0]); i++)
	{
		std::string n = kCases[i].name;
		if (sel == "all" || ("," + sel + ",").find("," + n + ",") != std::string::npos)
			run.push_back((int)i);
	}
	if (run.empty())
	{
		fprintf(stderr, "toe_csim: no case matches '%s'\n", sel.c_str());
		return 2;
	}
	printf("toe_csim: DATA_WIDTH %u, WINDOW_BITS %u (ring %u bytes), MSS %u, RX_DDR_BYPASS %d, logs in %s\n", DATA_WIDTH,
		   WINDOW_BITS, BUFFER_SIZE, MSS, (int)RX_DDR_BYPASS, logdir.c_str());
	fflush(stdout);
	std::vector<pid_t> pids(run.size());
	for (size_t k = 0; k < run.size(); k++)
	{
		const Case& cs = kCases[run[k]];
		fflush(NULL);
		pid_t pid = fork();
		if (pid == 0)
		{
			std::string lp = logdir + "/" + cs.name + ".log";
			int fd = open(lp.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
			if (fd >= 0)
			{
				dup2(fd, 1);
				dup2(fd, 2);
				close(fd);
			}
			alarm(3 * 3600);
			printf("=== %s: %s\n", cs.name, cs.what);
			bool ok;
			{
				// TOE_CSIM_LAT / TOE_CSIM_STALL override the card-memory latency (cycles) and stall rate (%)
				const char* el = getenv("TOE_CSIM_LAT");
				const char* es = getenv("TOE_CSIM_STALL");
				int lat = el && *el ? atoi(el) : cs.lat;
				int stall = es && *es ? atoi(es) : cs.stall;
				printf("=== memory latency %d cycles, %d %% stalls\n", lat, stall);
				Tb* tb = new Tb(0xC0FFEE + (uint32_t)run[k] * 7919, lat, stall); // leaked: _exit below
				ok = cs.fn(*tb) && !g_failed;
			}
			printf("=== %s %s after %llu cycles%s%s\n", cs.name, ok ? "PASS" : "FAIL", (unsigned long long)g_cycle,
				   ok ? "" : ": ", ok ? "" : g_failmsg.c_str());
			std::string rp = logdir + "/" + cs.name + ".result";
			FILE* f = fopen(rp.c_str(), "w");
			if (f)
			{
				fprintf(f, "%s %llu %s\n", ok ? "PASS" : "FAIL", (unsigned long long)g_cycle, ok ? "" : g_failmsg.c_str());
				fclose(f);
			}
			fflush(NULL);
			_exit(ok ? 0 : 1);
		}
		pids[k] = pid;
	}
	int failures = 0;
	std::vector<std::string> lines(run.size());
	for (size_t k = 0; k < run.size(); k++)
	{
		int st = 0;
		waitpid(pids[k], &st, 0);
		const Case& cs = kCases[run[k]];
		std::string res;
		std::string rp = logdir + "/" + cs.name + ".result";
		FILE* f = fopen(rp.c_str(), "r");
		if (f)
		{
			char buf[1200];
			if (fgets(buf, sizeof(buf), f))
				res = buf;
			fclose(f);
			while (!res.empty() && (res.back() == '\n' || res.back() == ' '))
				res.pop_back();
		}
		bool ok = WIFEXITED(st) && WEXITSTATUS(st) == 0;
		if (!ok)
			failures++;
		if (res.empty())
			res = WIFSIGNALED(st) ? ("CRASH signal " + std::to_string(WTERMSIG(st))) : "FAIL (no result)";
		lines[k] = res;
	}
	printf("\ntoe_csim results\n");
	for (size_t k = 0; k < run.size(); k++)
		printf("  %-4s %-82s %s\n", kCases[run[k]].name, kCases[run[k]].what, lines[k].c_str());
	printf("toe_csim: %d failed of %zu case(s)\n", failures, run.size());
	fflush(stdout);
	return failures ? 1 : 0;
}
