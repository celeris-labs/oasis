#include "oasis/operator.hpp"

#include "oasis/configuration.hpp"
#include "oasis/oasis_context.hpp"
#include "parcore/configuration.hpp"

#include <coyote/cDefs.hpp>
#include <coyote/cOps.hpp>

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace oasis {

void RDMASourceOperator::apply(libstf::stream_t stream, OasisContext &ctx) {
    ctx.config<RDMAReadConfig>()->enqueue_read(stream, offset_, size_);
}

void RDMASourceOperator::print(std::ostream &os) const {
    os << "RDMASource(offset=" << offset_ << ", size=" << size_ << ")";
}

void HTTPSourceOperator::apply(libstf::stream_t stream, OasisContext &ctx) {
    // HTTP ranges are inclusive on both ends, the column chunk extent is [offset, offset + size).
    // A zero-length chunk would underflow that conversion into a range ending at 2^64-1, which the
    // hardware would happily turn into a request for the rest of the object.
    if (size_ == 0) {
        throw std::runtime_error("HTTPSourceOperator: zero-length column chunk at offset " +
                                 std::to_string(offset_) + " in '" + path_ + "'");
    }
    ctx.config<HTTPReadConfig>()->read(stream, server_ip_, server_port_, path_, offset_,
                                       offset_ + size_ - 1, /*session_id*/ 0);

    // Debug-gated stage tracing. The HTTP handler going back to IDLE only proves the transfer
    // finished at the network edge; it says nothing about whether the body reached the decoder or
    // whether the decoder emitted anything. Sampling the decoder's in/out handshake counters
    // alongside the handler state localises a stall to one stage:
    //   in=0            -> body never arrived (strip_http / normalizer dropped it)
    //   in>0, out=0     -> decoder consumed but produced nothing (config or decode failure)
    //   in>0, out>0     -> decoder produced output, loss is in OutputWriter / OBM delivery
    // Detached and best-effort: it only reads CSRs, and OasisContext owns both configs for the
    // whole session so they outlive the samples.
    if (http_debug_enabled()) {
        std::thread([&ctx, stream] {
            auto http = ctx.config<HTTPReadConfig>();
            auto dec  = ctx.config<parcore::ColumnChunkDecoderConfig>();
            for (const int ms : {200, 1000, 5000}) {
                std::this_thread::sleep_for(std::chrono::milliseconds(ms));
                const auto prof = dec->read_profile(stream);
                std::fprintf(stderr,
                             "[oasis-http]   t=%-5dms %s\n"
                             "[oasis-http]              decoder in: hs=%llu starved=%llu stalled=%llu | "
                             "out: hs=%llu starved=%llu stalled=%llu\n",
                             ms, HTTPReadConfig::describe_status(http->debug_status()).c_str(),
                             static_cast<unsigned long long>(prof.in.handshakes_cycles),
                             static_cast<unsigned long long>(prof.in.starved_cycles),
                             static_cast<unsigned long long>(prof.in.stalled_cycles),
                             static_cast<unsigned long long>(prof.out.handshakes_cycles),
                             static_cast<unsigned long long>(prof.out.starved_cycles),
                             static_cast<unsigned long long>(prof.out.stalled_cycles));
            }
            // Coyote's shell counters close the last gap: "Sent local writes" says whether the
            // OutputWriter ever issued a host DMA, and "Notifications received" whether the
            // completion interrupt made it back. Decoder counters cannot see either.
            std::fflush(stderr);
            ctx.cthread()->printDebug();
        }).detach();
    }
}

void HTTPSourceOperator::print(std::ostream &os) const {
    os << "HTTPSource(path=" << path_ << ", range=[" << offset_ << "," << (offset_ + size_ - 1)
       << "])";
}

void HTTPBatchSourceOperator::apply(libstf::stream_t stream, OasisContext &ctx) {
    auto config = ctx.config<HTTPReadConfig>();

    // Split so no batch is larger than the hardware queue. The queue holds one entry per expected
    // response and every entry is pushed BEFORE the transfer is armed, so an oversized batch does
    // not back-pressure, it deadlocks: the host waits on a free entry, and entries are only freed
    // by responses, which cannot arrive until the arm that comes after them.
    //
    // A wide scale-30 row group at a 768 KiB chunk is thousands of GETs, so this is the normal path
    // rather than a guard against an exotic case. Successive sub-batches self-pace: the next one
    // blocks on entries the previous one is already draining.
    const size_t max_per_batch = config->max_batch_chunks();
    size_t       chunk_lo      = 0;
    while (chunk_lo < chunks_.size()) {
        HTTPReadConfig::RequestBatch batch;
        size_t                       chunk_hi = chunk_lo;
        while (chunk_hi < chunks_.size()) {
            HTTPReadConfig::RequestBatch probe;
            build_chunk(*config, chunks_[chunk_hi], probe);
            if (!batch.chunk_bytes.empty() &&
                batch.chunk_bytes.size() + probe.chunk_bytes.size() > max_per_batch) {
                break;
            }
            batch.text += probe.text;
            batch.chunk_bytes.insert(batch.chunk_bytes.end(), probe.chunk_bytes.begin(),
                                     probe.chunk_bytes.end());
            batch.request_bytes.insert(batch.request_bytes.end(), probe.request_bytes.begin(),
                                       probe.request_bytes.end());
            chunk_hi++;
        }
        // A single column chunk that alone exceeds the queue would loop forever otherwise.
        if (batch.chunk_bytes.size() > max_per_batch) {
            throw std::runtime_error(
                "HTTPBatchSourceOperator: column chunk at offset " +
                std::to_string(chunks_[chunk_lo].offset) + " needs " +
                std::to_string(batch.chunk_bytes.size()) +
                " queue entries, more than the hardware holds (" + std::to_string(max_per_batch) +
                ").");
        }
        // Revision 3 pads every GET on its own in emit_batch_slots(): there each GET is a transfer
        // of its own, and padding only the last one would leave the others with a DMA tail that the
        // hardware's drain would swallow together with the start of the next request.
        if (!config->slot_mode()) {
            const size_t before = batch.text.size();
            oasis::PadRequestTextToBeat(batch.text);
            // Keep the per-request lengths adding up to the text: the padding is inserted into
            // the LAST request.
            if (!batch.request_bytes.empty()) {
                batch.request_bytes.back() += static_cast<uint32_t>(batch.text.size() - before);
            }
        }
        emit_batch(stream, ctx, batch);

        // The decoder's handshake counters alongside every batch line. Without them a trace shows
        // the queue filling but not WHY nothing retires, because a chunk only retires when it
        // reaches tlast, and that needs the decoder to be accepting. The equivalent sampling in
        // HTTPSourceOperator never runs on this path -- the batch operator replaced it.
        //
        //   in stalled climbing   -> the decoder refuses input; nothing can retire
        //   in starved climbing   -> the decoder is idle waiting; the stall is upstream
        //   out handshakes flat   -> the decoder is not producing, so it is waiting, not busy
        if (http_debug_enabled()) {
            const auto prof = ctx.config<parcore::ColumnChunkDecoderConfig>()->read_profile(stream);
            // idle is the counter that was missing, and it is the one that matters. handshake /
            // starved / stalled only describe cycles WHILE a column chunk is streaming; the
            // profiler sits in IDLE between chunks and counts none of them. So a decoder that
            // looks 80% stalled in-chunk can still be idle most of the wall clock, waiting for the
            // host to configure the next chunk -- with the receive buffer already full of data it
            // has not been told about yet. Without this field the two cannot be told apart.
            std::fprintf(stderr,
                         "[oasis-http]   decoder in: hs=%llu starved=%llu stalled=%llu idle=%llu | "
                         "out: hs=%llu starved=%llu stalled=%llu idle=%llu\n",
                         static_cast<unsigned long long>(prof.in.handshakes_cycles),
                         static_cast<unsigned long long>(prof.in.starved_cycles),
                         static_cast<unsigned long long>(prof.in.stalled_cycles),
                         static_cast<unsigned long long>(prof.in.idle_cycles),
                         static_cast<unsigned long long>(prof.out.handshakes_cycles),
                         static_cast<unsigned long long>(prof.out.starved_cycles),
                         static_cast<unsigned long long>(prof.out.stalled_cycles),
                         static_cast<unsigned long long>(prof.out.idle_cycles));
        }
        chunk_lo = chunk_hi;
    }
}

void HTTPBatchSourceOperator::build_chunk(HTTPReadConfig &config, const Chunk &c,
                                          HTTPReadConfig::RequestBatch &batch) {
    // Ranges are inclusive on both ends and the chunk extent is [offset, offset + size). A
    // zero-length chunk would underflow into a range ending at 2^64-1, i.e. a request for the
    // rest of the object.
    if (c.size == 0) {
        throw std::runtime_error("HTTPBatchSourceOperator: zero-length column chunk at offset " +
                                 std::to_string(c.offset) + " in '" + path_ + "'");
    }
    config.read_streamed(server_ip_, server_port_, path_, c.offset, c.offset + c.size - 1, batch);
}

// Per-lane host-side traffic counters for the exit/stall dump. File-local on purpose (no header or
// class-layout change): GETs armed and body bytes requested, per lane, since the process started.
namespace {
std::atomic<uint64_t> g_lane_gets[16];
std::atomic<uint64_t> g_lane_bytes[16];
} // namespace

std::string HttpLaneTrafficSummary() {
    std::ostringstream o;
    o << "host traffic per lane (since process start):";
    for (int l = 0; l < 16; l++) {
        const auto g = g_lane_gets[l].load();
        if (g != 0) {
            o << " [lane " << l << ": " << g << " GETs, " << g_lane_bytes[l].load() << " body bytes]";
        }
    }
    return o.str();
}

namespace {

// A batch carries ONE lane for all its chunks, so every chunk in it must belong to the stream
// this operator runs on. That holds when each flow submits its own chunk (OASIS_HTTP_BATCH=0):
// the decode config and the request are applied on the same stream by construction.
//
// It does NOT hold for a row-group batch, whose chunks come from sibling flows the scheduler
// may have placed on other streams. With one decoder that was harmless -- every stream was 0.
// With more than one it would route a column's bytes to a decoder configured for a different
// column, which corrupts silently. Refuse rather than corrupt.
void RefuseCrossStreamBatch(OasisContext &ctx, const HTTPReadConfig::RequestBatch &batch) {
    if (batch.chunk_bytes.size() > 1) {
        const auto decoders = ctx.config<parcore::ColumnChunkDecoderConfig>()->num_decoders();
        if (decoders > 1) {
            throw std::runtime_error(
                "HTTPBatchSourceOperator: a multi-chunk batch cannot target " +
                std::to_string(decoders) +
                " decoders -- its chunks may belong to different streams. Run with "
                "OASIS_HTTP_BATCH=0 (one request per column chunk), or give the batch a per-chunk "
                "lane before enabling multi-decoder batching. This is also the required mode on a "
                "multi-session bitstream (--multi): there each lane owns its own TCP connection and "
                "its own request-text stream, so a batch spanning lanes has no single destination "
                "to be DMA'd to.");
        }
    }
}

} // namespace

void HTTPBatchSourceOperator::emit_batch(libstf::stream_t stream, OasisContext &ctx,
                                         const HTTPReadConfig::RequestBatch &batch) {
    if (batch.chunk_bytes.empty()) {
        return;
    }
    auto config = ctx.config<HTTPReadConfig>();
    RefuseCrossStreamBatch(ctx, batch);

    // CSR revision 3 (HBM slots): one arm per GET, each waiting for its connection's slot to be
    // drained. Everything below this branch is the revision-2 path, unchanged.
    if (config->slot_mode()) {
        emit_batch_slots(ctx, *config, batch, config->lane_for_stream(stream));
        return;
    }

    // Into a Coyote-visible buffer. LOCAL_READ needs a 64 B-aligned source or it emits databeats
    // with a broken keep signal, which the memory pool guarantees.
    //
    // Kept in a vector, not a single member: the DMA is asynchronous, so a sub-batch's buffer must
    // stay alive until its transfer completes. Overwriting one member per sub-batch would free the
    // bytes the hardware is still reading.
    // Round the allocation up to a whole 64-byte beat and ZERO the tail.
    //
    // Coyote moves whole beats, so a 132-byte buffer is transferred as 192. The hardware discards
    // what follows the announced length (ST_DRAIN in http_req_stream), but the pool recycles
    // buffers, so those trailing bytes hold the PREVIOUS batch's request text. Before the drain
    // existed they became the next request's prefix and the server saw "osGET ..." -- "os" out of
    // an older "Host:" -- and answered 400.
    //
    // Zeroing does not fix that; the drain does. It makes the next occurrence obvious instead of
    // plausible: NUL bytes are visibly wrong on the wire, whereas fragments of real HTTP look like
    // a protocol bug and cost days.
    // The text was already padded to a whole beat when the batch was assembled, so this is a
    // no-op in the normal case; it stays as a backstop for any path that skips that.
    const size_t beat    = 64;
    const size_t padded  = ((batch.text.size() + beat - 1) / beat) * beat;
    libstf::Status status;
    auto           buf = libstf::make_buffer(ctx.memory_pool(), padded, status);
    if (!buf) {
        throw std::runtime_error("HTTPBatchSourceOperator: could not allocate " +
                                 std::to_string(padded) + " bytes for request text");
    }
    std::memcpy(buf->ptr, batch.text.data(), batch.text.size());
    std::memset(static_cast<std::byte *>(buf->ptr) + batch.text.size(), 0,
                padded - batch.text.size());
    // The hardware is told the REAL length; the padding exists only to make the DMA's beat count
    // exact, and never reaches the wire.
    buf->size = padded;
    ctx.tlb_manager()->ensure_tlb_mapping(buf->ptr, buf->capacity);
    text_buffers_.push_back(buf);

    // Tell the hardware what is coming: one bit per expected response, then the arm. This must
    // precede the DMA -- the arm is what opens the connection, and the queue entries have to be in
    // place before any response can arrive. (The cross-stream refusal that used to sit here runs
    // at the top of this function now, before anything is allocated.)
    // ONE lane for the whole batch, decided here and passed to everything that needs it. It used to
    // be re-derived at each use -- submit_batch from `stream & 0xF`, the DMA sink from
    // `stream % lanes` -- which are the same number only while the scheduler keeps its stream count
    // at or below the bitstream's lane count. When they disagreed, a batch's queue entries and its
    // request text went to DIFFERENT lanes, and nothing on either side could notice.
    const uint8_t lane = config->lane_for_stream(stream);

    lane_.store(lane);
    gets_total_.fetch_add(batch.request_bytes.empty() ? 1 : batch.request_bytes.size());
    g_lane_gets[lane & 15].fetch_add(batch.request_bytes.empty() ? 1 : batch.request_bytes.size());
    for (const auto b : batch.chunk_bytes) {
        g_lane_bytes[lane & 15].fetch_add(b);
    }
    config->submit_batch(server_ip_, server_port_, batch, lane);
    gets_armed_.fetch_add(batch.request_bytes.empty() ? 1 : batch.request_bytes.size());

    // Then the text itself.
    //
    // TWO DIFFERENT THINGS ARE CALLED A "STREAM" HERE, and sending the text to the wrong one
    // deadlocks the handler:
    //
    //   - the DECODE LANE, which is `stream`. It travels in bits [35:32] of the chunk-length
    //     register, set by submit_batch above, and never through the DMA descriptor.
    //   - the HOST-DMA SINK, which is this `dest`, the axis_host_recv index the FPGA reads the
    //     request text from.
    //
    // Which sink is correct depends on the bitstream, so ask it rather than assume:
    //
    //   - ONE session (handler_stream, lane_count()==1): only axis_host_recv[0] is wired -- the
    //     handler's s_axis_req connects to it and vfpga_top.svh ties off [1..N_STRM_AXI-1]. All
    //     text goes to 0 whatever decode lane the chunk is bound for.
    //   - N sessions (handler_multi, lane_count()>1): each lane owns a session AND its own request
    //     stream, so lane L's text must go to axis_host_recv[L]. Sending it to 0 would hand every
    //     lane's GETs to lane 0's connection.
    //
    // Getting this wrong is silent. A tied-off stream holds tready high and discards, so the DMA
    // reports success while the text vanishes; the handler has already been armed by submit_batch,
    // so it waits for bytes that no longer exist -- await_cfg_ready times out at 30 s, the read
    // watchdog fires a dirty_abort, the body stream stops draining, and the receive window
    // collapses to zero with the TOE retransmitting into a dead peer. One wrong descriptor field.
    //
    // It stayed invisible until the second decoder existed, because every flow was on stream 0.
    const uint8_t          lanes    = config->lane_count();
    const libstf::stream_t req_dest = (lanes > 1) ? static_cast<libstf::stream_t>(lane)
                                                  : static_cast<libstf::stream_t>(0);
    auto *byte_ptr = static_cast<std::byte *>(buf->ptr);
    for (size_t off = 0; off < buf->size; off += coyote::MAX_TRANSFER_SIZE) {
        coyote::localSg sg;
        sg.addr   = reinterpret_cast<void *>(byte_ptr + off);
        sg.len    = std::min(buf->size - off, coyote::MAX_TRANSFER_SIZE);
        sg.stream = coyote::STRM_HOST;
        sg.dest   = req_dest;
        const bool last = off + coyote::MAX_TRANSFER_SIZE >= buf->size;
        ctx.cthread()->invoke(coyote::CoyoteOper::LOCAL_READ, sg, last);
    }

    // WAIT FOR THE TRANSFER TO DRAIN BEFORE RETURNING.
    //
    // The DMA is asynchronous and this buffer belongs to the operator, so it is freed when the
    // query's operator is destroyed. If the query ends first, the hardware is left mid-transfer:
    // http_req_stream sits in ST_SEND_DATA waiting for bytes that will never come, stream_busy
    // never clears, and since an arm is only admitted when !stream_busy, EVERY LATER QUERY blocks
    // forever waiting for a config beat.
    //
    // It is not subtle on the wire once you see it: a q4 run was still transmitting q2's request
    // text -- GETs for supplier and region, two queries after the query that built them -- onto a
    // connection the server had already reset.
    //
    // req_total_bytes still holds this batch's length, so req_ready currently reports the ARM
    // condition, which is exactly !stream_busy. Waiting on it here is therefore a wait for this
    // transfer to finish sending. It costs only as long as a few KB of request text takes to go
    // out, and it guarantees the buffer outlives the DMA reading it.
    //
    // Asked of THIS LANE, not of the config port in general. ARM_READY for lane L is !stream_busy[L]
    // -- exactly "this lane's transfer has finished sending" -- whereas the old OR-folded req_ready
    // answered for whichever lane was addressed last, which after a neighbour's beat is a different
    // lane's answer to a different question. The wait would then end early and the buffer be freed
    // under a DMA still reading it.
    config->await_cfg_ready("request text to finish sending", lane, HTTPReadConfig::LaneAdmit::Arm);
}

// CSR revision 3 (HBM slots, handler_slots): the same protocol as the revision-2 path above, one GET
// at a time.
//
// WHY ONE ARM PER GET. A connection's slot in card memory holds ONE response: the reader drains it
// into the decoder's framer and may only move on once the slot is empty (strip_http keeps mid-beat
// residue across responses). The hardware enforces that by giving each arm exactly one reader entry
// and by holding ARM_READY low until the slot is released. So a text announcing several GETs under
// one arm -- which is all the revision-2 path ever does -- would land several responses in a slot the
// reader drains as one, and the connection would go FATAL on the residue. Each GET is therefore its
// own arm, its own DMA and, because the hardware drains its request stream to the DMA's TLAST, its
// own beat-padded region of the buffer.
//
// REVISION 4 (pipelined slots) keeps the one-arm-per-GET shape but drops the drain wait: arm k+1 is
// taken as soon as GET k's text has gone out, and the slot is metered by bytes (reserve_slot_bytes,
// charged before each arm) instead of by occupancy. The rest of this note is about revision 3.
//
// When there is more than one GET (a column chunk larger than max_get_bytes(), or an
// OASIS_HTTP_CHUNK_BYTES split), arm k+1 waits inside arm_transfer() for response k to drain, and
// that wait runs on the dispatcher thread. It is correct and it is slow: other lanes get no NEW work
// placed while it lasts. At the default row-group sizes every chunk is one GET, so this path is the
// exception; the fix, if it ever matters, is host-side splitting into separate flows (stage 2, WP6).
//
// The chunk-length entries go first, all of them, exactly as on revision 2: one per COLUMN CHUNK,
// however many GETs it was split into, because axis_rewrite_last marks tlast by byte count.
void HTTPBatchSourceOperator::emit_batch_slots(OasisContext &ctx, HTTPReadConfig &config,
                                               const HTTPReadConfig::RequestBatch &batch,
                                               uint8_t lane) {
    auto requests = HTTPReadConfig::SplitRequests(batch);
    if (requests.empty()) {
        return;
    }

    // Pad every GET to a whole beat on its own (see PadRequestTextToBeat), and lay them out at
    // 64-byte aligned offsets in ONE buffer: LOCAL_READ needs an aligned source, and each GET is a
    // separate transfer ending in its own TLAST.
    constexpr size_t beat = 64;
    std::vector<size_t> offs, lens;
    size_t              total = 0;
    for (auto &r : requests) {
        oasis::PadRequestTextToBeat(r);
        offs.push_back(total);
        lens.push_back(r.size());
        total += ((r.size() + beat - 1) / beat) * beat;
    }
    libstf::Status status;
    auto           buf = libstf::make_buffer(ctx.memory_pool(), total, status);
    if (!buf) {
        throw std::runtime_error("HTTPBatchSourceOperator: could not allocate " +
                                 std::to_string(total) + " bytes for request text");
    }
    auto *byte_ptr = static_cast<std::byte *>(buf->ptr);
    std::memset(byte_ptr, 0, total);
    for (size_t i = 0; i < requests.size(); i++) {
        std::memcpy(byte_ptr + offs[i], requests[i].data(), requests[i].size());
    }
    buf->size = total;
    ctx.tlb_manager()->ensure_tlb_mapping(buf->ptr, buf->capacity);
    // Lives as long as this operator, i.e. until the flow retires -- which needs every response,
    // which needs every GET to have been sent. So the DMA can never outlive its source.
    text_buffers_.push_back(buf);

    lane_.store(lane);
    gets_total_.fetch_add(requests.size());
    g_lane_gets[lane & 15].fetch_add(requests.size());
    for (const auto b : batch.chunk_bytes) {
        g_lane_bytes[lane & 15].fetch_add(b);
    }
    config.push_entries(batch, lane);

    // The request-text sink is the lane on a multi-connection bitstream (see emit_batch).
    const uint8_t          lanes    = config.lane_count();
    const libstf::stream_t req_dest = (lanes > 1) ? static_cast<libstf::stream_t>(lane)
                                                  : static_cast<libstf::stream_t>(0);
    for (size_t i = 0; i < requests.size(); i++) {
        // Revision 4: charge this GET's response against its connection's slot before arming it
        // (a no-op on revision 3, where the hardware holds the arm until the slot is empty). A GET
        // whose range cannot be read back is charged as the largest legal one, which only ever
        // makes the wait longer.
        if (config.slot_pipelined()) {
            uint64_t body = HTTPReadConfig::RequestRangeBytes(requests[i]);
            if (body == 0) {
                body = config.max_get_bytes();
            }
            config.reserve_slot_bytes(lane, body);
        }
        // The REAL length, not the padded one: the hardware sends exactly this many bytes and
        // swallows the rest of the transfer up to TLAST.
        config.arm_transfer(server_ip_, server_port_, static_cast<uint32_t>(lens[i]), lane);
        // Proof the arm was taken before anything else is written -- the next GET's arm, or the
        // next flow's entries, would otherwise rewrite the registers it is sampled from.
        config.await_arm_consumed(lane);
        gets_armed_.fetch_add(1);

        const size_t padded = ((lens[i] + beat - 1) / beat) * beat;
        for (size_t off = 0; off < padded; off += coyote::MAX_TRANSFER_SIZE) {
            coyote::localSg sg;
            sg.addr   = reinterpret_cast<void *>(byte_ptr + offs[i] + off);
            sg.len    = std::min(padded - off, coyote::MAX_TRANSFER_SIZE);
            sg.stream = coyote::STRM_HOST;
            sg.dest   = req_dest;
            // TLAST on every GET's final beat: http_req_stream drains to TLAST after the
            // announced length, so a transfer spanning two GETs would lose the second.
            const bool last = off + coyote::MAX_TRANSFER_SIZE >= padded;
            ctx.cthread()->invoke(coyote::CoyoteOper::LOCAL_READ, sg, last);
        }
        gets_sent_.fetch_add(1);
    }

    // No wait for "the text has gone out" here, unlike the revision-2 path. There that wait is
    // ARM_READY, which is !stream_busy on handler_multi. On handler_slots ARM_READY also carries the
    // depth-1 credit, so the same wait would block this (dispatcher) thread until the whole
    // RESPONSE had been drained, serialising every lane behind this one. And it is not needed: the
    // arm was proven consumed above, and the buffer lives until the flow retires (see above).
    if (http_debug_enabled()) {
        std::fprintf(stderr,
                     "[oasis-http] slot batch: lane %u, %zu column chunk(s), %zu GET(s), %zu bytes of "
                     "request text | %s\n",
                     unsigned(lane), batch.chunk_bytes.size(), requests.size(), total,
                     config.conns().describe().c_str());
    }
}

void HTTPBatchSourceOperator::print(std::ostream &os) const {
    os << "HTTPBatchSource(path=" << path_ << ", chunks=" << chunks_.size();
    for (const auto &c : chunks_) {
        os << " [" << c.offset << "+" << c.size << "]";
    }
    os << ", lane=" << lane_.load() << ", GETs armed " << gets_armed_.load() << " / DMA'd "
       << gets_sent_.load() << " / total " << gets_total_.load() << ")";
}

void LocalSourceOperator::apply(libstf::stream_t stream, OasisContext &ctx) {
    // LOCAL_READ into `stream`, chunked at MAX_TRANSFER_SIZE. The TLB mapping must exist first.
    const auto &buffer   = input_buffer_;
    auto       *byte_ptr = static_cast<const std::byte *>(buffer->ptr);
    ctx.tlb_manager()->ensure_tlb_mapping(buffer->ptr, buffer->capacity);

    auto cthread = ctx.cthread();
    for (size_t off = 0; off < buffer->size; off += coyote::MAX_TRANSFER_SIZE) {
        auto  *curr_ptr   = reinterpret_cast<void *>(const_cast<std::byte *>(byte_ptr) + off);
        size_t input_size = std::min(buffer->size - off, coyote::MAX_TRANSFER_SIZE);

        coyote::localSg sg;
        // Coyote needs a 64B-aligned source address or it emits databeats with a broken keep
        // signal.
        assert((reinterpret_cast<uintptr_t>(curr_ptr) % 64) == 0);
        sg.addr   = curr_ptr;
        sg.len    = input_size;
        sg.stream = coyote::STRM_HOST;
        sg.dest   = stream;

        bool last_transfer = off + coyote::MAX_TRANSFER_SIZE >= buffer->size;
        cthread->invoke(coyote::CoyoteOper::LOCAL_READ, sg, last_transfer);
    }
}

void LocalSourceOperator::print(std::ostream &os) const {
    os << "LocalSource(ptr=" << input_buffer_->ptr << ", size=" << input_buffer_->size << ")";
}

void DecodeColumnChunkOperator::apply(libstf::stream_t stream, OasisContext &ctx) {
    auto config = ctx.config<parcore::ColumnChunkDecoderConfig>();
    config->enqueue_column_chunk(stream, compression_, num_values_, type_);
}

void DecodeColumnChunkOperator::print(std::ostream &os) const {
    os << "DecodeColumnChunk(compression=" << compression_ << ", num_values=" << num_values_
       << ", type=" << type_ << ")";
}

void LocalSinkOperator::apply(libstf::stream_t stream, OasisContext &ctx) {
    libstf::stream_mask_t mask;
    mask.set(stream);
    handle_ = ctx.output_buffer_manager()->acquire_output_handle(mask);
}

void LocalSinkOperator::print(std::ostream &os) const {
    os << "HostBufferSink(tag=" << tag_ << ")";
}

} // namespace oasis
