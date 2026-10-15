# Removing the file -> pinned-pool CPU copy: investigation (read-only)

Date 2026-10-14, host hacc-u55c-05. Nothing was edited, run on the FPGA, or simulated.
Tags: **[V]** verified in source/on the host, **[I]** inference, **[U]** could not verify.

## 0. Bottom line

| Option | Removes copy? | Verdict |
|---|---|---|
| A: pinned-pool chunk cache | Yes, for repeat scans in one process only | Feasible, small (~250-350 LOC), low risk. Best first step. Needs nothing from the driver or HW. |
| B: mmap page cache + userMap | In theory | No-go as is. Driver pin flags fail or COW on ext4; 4 KiB-page TLB path is hopeless (see 2). |
| C: files on 1 GiB hugetlbfs, mmap + userMap | Yes, even across processes | Feasible, medium (~300 LOC + ops setup). Only option that is zero-copy from first touch. Needs a `userMap` smoke test on the card. |
| D: O_DIRECT | Yes (DMA into pool) | No-go on this host: the data disk is a 10K-rpm SAS HDD [V]. |
| E: cheaper copy | No | Non-temporal copy is a modest win; fewer scan threads is a free win; byte count is already ~1.0x. |

Predicted DRAM traffic per input byte drops from about 5-6B to 3B (-40..-50%). The experiment in section 7
(~40 LOC, throwaway) tells us whether that moves the 9.7 -> 12.6 GB/s gap before we build anything.

## 1. Option A: cache read buffers in the pinned pool

### Where the bytes come from today [V]
- `extension/src/coalesced_fetcher.cpp:62-87` `PrepareReads()`: for every merged range, `memory_pool->allocate(m.size,&ptr)`
  (line 79) then `libstf::make_buffer(...)` (line 84). `:89-98` `ExecuteMergedRead()`: `file_handle.Read(m.buffer->ptr, m.size, m.offset)`
  (line 97). DuckDB `LocalFileSystem::Read` is a plain `pread` loop (`extension/duckdb/src/common/local_file_system.cpp:565`).
- Callers: `extension/src/oasis_scan.cpp:429-459` (`if (!rdma)`, one `CoalescedFetcher` per row group, read synchronously on the
  worker) and `extension/src/oasis_hardware_bloom.cpp:390-397` (build side, one fetcher per build chunk, `MakeHostSource(fetcher.Resolve(range))`).
- The FPGA never writes input buffers [V]: `hardware/src/hdl/local_read.sv` only has `sq_rd` (opcode LOCAL_READ, via `read_req_generator.sv:58`) and the
  `axis_host_recv` input; the only `sq_wr` users are the output writers (`parcore/libstf/hardware/src/hdl/output/stream_writer.sv:65`), which
  target buffers enqueued by `OasisContext::enqueue_output_buffer` (`software/oasis/oasis_context.cpp:204`). Software also never mutates input
  buffers: `MakeHostSource` (`oasis_hardware_bloom.cpp:153-160`) wraps a *copy* of the Buffer header; `pc.buffer->size = bytes_written`
  (`scheduler.cpp` handle_completion) touches output buffers only. (The driver pins with FOLL_WRITE/DMA_BIDIRECTIONAL, which is a mapping property, not a use.)

### Lifetime today [V]
- `PendingGroup::fetcher` (`include/oasis_scan.hpp:272`) owns the merged buffers. It dies at `lstate.inflight.pop_front()` (`oasis_scan.cpp:754`),
  right after the group's outputs are collected. The `LocalSourceOperator` slice (`software/oasis/operator.hpp:67-78`) holds the parent
  `shared_ptr<Buffer>` until the scheduler reaps the flow (`scheduler.cpp` reap/handle_completion). `BufferDeleter` returns the memory to jemalloc
  (`arena dirty_decay_ms=0`, `memory_pool.cpp:100`), so the next allocation may or may not get the same address (see section 7).
- The whole 8 GiB pool is pre-mapped in the FPGA TLB at context init (`oasis_context.cpp:82-85`), so no `userMap` happens mid-run for pool buffers.

### What would change
1. New `PinnedChunkCache` (extension-side, owned by `OasisContext` or a function-local leaked static):
   `unordered_map<Key, shared_ptr<Buffer>>`, `Key = {path, last_modified, file_size, offset, size}`, mutex, byte budget, LRU list.
   `last_modified` and `version_tag` already exist in `bind_data.parquet_metadata` (`parquet_file_metadata_cache.hpp:60-61`), so validation costs no syscall.
   `FileSystem::GetLastModifiedTime(FileHandle&)` (`file_system.hpp:192`) is the fallback.
2. `CoalescedFetcher::PrepareReads` (line 76-86): look up each merged range before `allocate`; on hit set `m.buffer = cached`, `m.cached = true`.
   `ExecuteMergedRead` (line 97): `if (m.cached) return;` else read, then publish the buffer into the cache **after** the read completes
   (another worker may hit it immediately). The constructor needs the cache pointer and file identity.
3. `oasis_hardware_bloom.cpp:390-397` goes through the same `CoalescedFetcher`, so the build side is covered for free (build chunk = one range = one entry).
4. Setting `oasis_chunk_cache_mb` (0 = off) in `oasis_settings.cpp`.
- LOC: cache class 100-150, fetcher 30-40, wiring/settings 30, tests 100 -> roughly 250-350.

### Design points and risks
- **Key granularity [I]**: merged ranges depend on projection (`PrepareReads` may add the whole span, line 70-71). An exact-match key misses when the projection
  changes between queries, and the same bytes can then be cached twice. Alternative: always cache the whole row-group span (one entry per group). That costs up to +50% first-touch bytes for a 2-of-3 projection.
- **Sizing vs the 8 GiB pool [V/I]**: `HugePageMemoryPool` takes all free 1 GiB pages (8 here: `/sys/kernel/mm/hugepages/hugepages-1048576kB/{nr,free}_hugepages` = 8/8).
  The same arena serves output buffers (`allocate_output_buffer`, `oasis_context.cpp:189-202`). In flight: ~workers(32) x depth(2) x (input + output ~ 3+3 MiB) ~ 0.4 GiB at 128K-row groups, more with big groups.
  A cache budget of at most 50% of `total_capacity()` is needed. `allocate` failure currently throws `IOException` (`coalesced_fetcher.cpp:80`); the cache must evict-and-retry.
  jemalloc does not compact, so long-lived cache entries interleaved with transient buffers can fragment large allocations [I].
- **Eviction safety [V]**: dropping the cache's `shared_ptr` is safe while a flow still holds a slice (parent ref).
- **Concurrency [I]**: one lookup per merged read (~100s/s), a plain mutex is fine. Groups are claimed once per scan (`next_group.fetch_add`, `oasis_scan.cpp:630`), so
  two workers do not race on one key within a scan; across scans the second just drops its duplicate insert.
- **`oasis_prefetch_depth`**: unchanged semantics; with hits `PrefetchGroup` becomes cheap, so the worker is no longer blocked in `pread` and the pipeline is limited by splinter submit.
- **File changes [I]**: stale if the file is rewritten with identical mtime+size; the same weakness as DuckDB's own metadata cache. Validate once at scan init, not per read.
- **RDMA path**: untouched (`if (!rdma)`); RDMA reads already bypass the CPU.
- **Limits**: only helps the 2nd+ scan of the same bytes in one process. Each bench point is one process with 3 warmup + 10 measured iterations, so the measured iterations are all hits.
  A cold first scan, and every first query of a fresh process, still pays the copy. Say so when quoting numbers.

## 2. Option B: mmap(page cache) + `cthread->userMap`

Verdict: **no-go without a driver patch, and even then a bad fit.**
- Driver classification [V] `vfpga_gup.c:38-40`: `is_vm_hugetlb_page(vma)` is false for an ext4 mapping, so it takes `stlb_meta` (4 KiB). The coalescing branch (`:166-184`)
  needs 2^(30-12)=262144 physically contiguous, 1 GiB-aligned 4 KiB pages (`n_pages_in_huge`, `coyote_setup.c:78`), which never holds for page cache.
- Pin flags [V] `vfpga_gup.c:301`: `pin_user_pages_remote(..., FOLL_WRITE | FOLL_LONGTERM, ...)`. Kernel 6.8 mm/gup.c is not on the host, so the next is **[U], from memory of the kernel**:
  with `PROT_READ` the VMA lacks VM_WRITE, so FOLL_WRITE without FOLL_FORCE returns -EFAULT. With `MAP_SHARED|PROT_WRITE` on ext4, long-term writable pins of
  dirty-tracked file mappings are refused (-EFAULT, `writable_file_mapping_allowed`). With `MAP_PRIVATE|PROT_WRITE` the write-fault COW-copies every page, i.e. a copy again.
  So the driver would have to change flags (read-only FOLL_PIN, no LONGTERM), which means rebuilding and reloading the module (and the known rmmod wedge risk, see memory `bloom_20k_input_short`).
- TLB geometry [V] defaults in `parcore/libstf/coyote/cmake/FindCoyoteHW.cmake:107-120`, hardware/CMakeLists.txt overrides only `TLBL_BITS 30` (line 50):
  small TLB = 2^10 sets x 4 ways = 4096 entries x 4 KiB = **16 MiB reach**; large TLB = 2^9 x 2 = 1024 x 1 GiB. (A built bitstream could differ; not checked.)
- Fault cost [V/I]: `MAX_N_MAP_PAGES = 256` (`coyote_defs.h:328`) so one miss maps <= 1 MiB; each entry is two uncached MMIO writes (`vfpga_hw.c:105-110`);
  `map_present` walks the whole hash table (`vfpga_gup.c:119`). At 12 GB/s a MiB takes ~87 us; a fault with 256 entries plus interrupt plus lock toggles is very likely several x that [I, not measured].
  Pool pages avoid all of this because they are pre-mapped once as 1 GiB entries.
- `TLBManager` [V]: `tlb_manager.cpp:26` `memory_pool->get_page_boundaries` throws for any address outside the pool (`memory_pool.cpp:213-219`). It also assumes "never evicted" (header comment).
- Mid-run `userMap` toggles the MMU lock twice per ioctl, and the known `tlb_fsm` bug can drop a faulted request then (memory `bloom_20k_input_short`). B would hit exactly that.

## 3. Option C: parquet files on 1 GiB hugetlbfs, mapped directly

Verdict: **feasible and the only truly zero-copy-from-first-touch option; medium effort, needs one on-card smoke test.**
What it needs:
1. System: `mount -t hugetlbfs -o pagesize=1G,size=<N>G none /mnt/huge1g` (the current mount is `pagesize=2M`, `mount` output). The pages come from the same `nr_hugepages=8`.
   Files must be resident **before** the extension starts, because `HugePageMemoryPool` grabs *all remaining free* 1 GiB pages (`memory_pool.cpp:103-105`, `:148-165`).
   Pool shrinks to 8 - (file pages); a 384 MiB probe file still consumes one full 1 GiB page. SF10 uncompressed lineitem7 (~3.4 GB [I]) leaves ~4 GiB for the pool.
2. Populating: hugetlbfs has no `write(2)` path [I, from memory]; use `ftruncate` + `mmap(MAP_SHARED)` + memcpy (a small helper script). `read(2)` works [I], so DuckDB's `ParquetReader`
   bind/metadata reads on that path should work unchanged. File data persists across processes, so even the first iteration of each bench process skips the copy.
3. Mapping must be `MAP_SHARED, PROT_READ|PROT_WRITE`: MAP_PRIVATE would COW on the FOLL_WRITE pin (a 1 GiB copy); read-only would -EFAULT as in B. hugetlbfs has no dirty tracking so the
   long-term writable pin should be accepted [U, kernel rule from memory]; the pool itself is anonymous MAP_HUGETLB which is known to work. The driver then takes the huge path
   (`is_vm_hugetlb_page`, `vfpga_gup.c:39`) with n_pages_in_huge = 262144; it requires 1 GiB pages (2 MiB hugetlbfs would break the `dma_map_single(.., ltlb_meta->page_size)` assumption, `:334-339`).
   The address is 1 GiB aligned (hugetlb unmapped-area alignment [I]).
4. `TLBManager` (`tlb_manager.{hpp,cpp}`): add `register_external_region(base, len)` and consult it in `ensure_tlb_mapping` before `get_page_boundaries`; unmap order must be
   `userUnmap` -> `munmap`. Do the `userMap` at scan init, before any submit, to dodge the mid-run toggle bug (no TLB misses are in flight at that point, but keep it away from running flows anyway).
5. `LocalSourceOperator::apply` (`operator.cpp:21-33`) needs no change once (4) exists. The 64 B-alignment assert (`:28`) holds only if chunk offsets are 64 B-aligned in the file;
   the HW already strips heads (`local_read.sv:71-75`, `read_req_generator.sv:70-71`), so the assert is stale w.r.t. the current RTL [I; the loaded bitstream is not verified]. Parquet chunk offsets are arbitrary, so relax it.
6. Extension: in `PrefetchGroup` (`oasis_scan.cpp:429`) detect `fstatfs(f_type == HUGETLBFS_MAGIC)`, mmap once per file (cached on the context), and build `RangeView`s straight from
   `base + cc.offset` instead of using `CoalescedFetcher`. The same for the build side (`oasis_hardware_bloom.cpp:390`). ~120 LOC extension + ~40 TLBManager + ~60 helper.
7. Risks: pool shrinkage and the "pool grabs everything" ordering; a hung run wedging the card (memory `hw_run_hang_wedges_device`); bench harness must copy data to the hugetlbfs mount and
   stay under (8 - pool_min) GiB; file path semantics change (data lives in RAM, not a durable disk).

## 4. Option D: O_DIRECT into the pinned buffer

Verdict: **no-go here.**
- `lsblk` [V]: `/` and `/local` are LVM on `sda`, `ST1200MM0099` (10K SAS HDD, ROTA=1). Cold reads would be ~0.2 GB/s, far below the 9-12 GB/s needed. The bench files are page-cache resident,
  and `O_DIRECT` bypasses (does not read) clean cached pages on ext4, so it forces cold-disk speed even for hot data. `FILE_FLAGS_DIRECT_IO` exists in DuckDB (`local_file_system.cpp:479`).
- Mechanically it would work on hugetlb memory (GUP-based DMA into the pool): the read must be [floor4k(off), ceil4k(end)) into a 4 KiB-aligned buffer (`allocate(size, 4096, &p)`; the default alignment is 64,
  `memory_pool.hpp`), and the chunk starts `off % 4096` into the buffer (see C.5 on the 64 B assert). Row-group spans are not 4 KiB-aligned, so up to 8 KiB extra per read. On NVMe with >12 GB/s this would be viable; not here.

## 5. Option E: make the copy cheaper / smaller

Bytes actually read, for this benchmark's 3-column INT64 uncompressed probe file [V from code + `gen_data.py`: row groups <= 131072 rows, `MAX_ROW_GROUP_ROWS` line 55; plain, OPTIONAL]:
- Chunk ~1 MiB (131072 x 8 B + page header + def-level bytes). Chunks of a row group are adjacent, so the three registered ranges (and the whole span) merge into **one** `pread` of ~3 MiB per group
  (`MergeComparator` gap 16 KiB, `coalesced_fetcher.cpp:8-18`).
- All three projected: `registered_bytes / group_span = 1.0 > 0.95` -> whole span registered (`:68-71`), but it equals the chunks, so no waste. Bytes read / decoded bytes ~ 1.00x.
  With `file_columns > columns` (sweep_columns) the ratio is < 0.95 and only the projected chunks are read: still 1.0x.
- Snappy: bytes read < decoded bytes (compression ratio); the copy is proportionally smaller.
- Possible waste [I, from reading the code; not tested]: when >= 95% of the span is projected but an unprojected chunk is > 16 KiB (e.g. 24 of 25 columns), the whole-span range overlaps two merged slots.
  `std::set::find` widens only one; the other read stays. The whole span is then read **plus** the other slot again (up to ~2x bytes), and the widened part is never used because chunk ranges
  still resolve to their original slots (`Resolve`, `:101-112`). Not hit by the 3-column bench. The heuristic buys nothing here anyway: each chunk is sliced separately for the FPGA, and the merge
  already coalesces within 16 KiB. Cheap fix: skip the whole-span registration in oasis.
- Non-temporal copy: pread (kernel `rep movsb`, cached stores, pollutes L3) cannot do NT. Replacement = `mmap` the file + AVX2 `_mm256_stream_si256` copy into the pool buffer: avoids the RFO and L3 pollution,
  but still reads B from page cache and writes B to DRAM, and adds minor-fault overhead (mitigate with `MADV_POPULATE_READ`). Expected gain ~10-20% of traffic [I].
- Fewer copying threads: the number of bytes does not change, but the measured thread sweep already shows 1-4 threads reach 12.6 GB/s while 16-32 give ~9.7. The scan is FPGA-bound and uses ~4.5 cores,
  so capping scan workers (e.g. `SET threads = 4..8` or an oasis worker cap) is a free win [V measurement, from the task brief].

## 6. DRAM traffic per input byte (B = one compressed input byte; uncompressed plain, so decoded ~ B)

Assumptions [I]: working set (384 MiB-1.5 GiB) >> 128 MiB L3 so page-cache and output reads come from DRAM; the pinned buffer is evicted from L3 before the FPGA reads it
in the worst case; DMA writes are full-line (no RFO); the kernel copy may or may not RFO (not measured on Zen 2); output is consumed once by the CPU (hash probe / aggregate).

| Component | Today | A (hit) / C (zero-copy) |
|---|---|---|
| page-cache read (copy source) | 1.0 B read | 0 |
| pinned buffer write (+RFO if any) | 1.0 B write (+0..1.0 B read) | 0 (A: only on first touch) |
| FPGA DMA read of input | 1.0 B read | 1.0 B read |
| FPGA C2H output write | 1.0 B write | 1.0 B write |
| CPU read of output | 1.0 B read | 1.0 B read |
| **Total** | **5.0 B (6.0 with RFO)** | **3.0 B** |

At 12.6 GB/s: ~63-76 GB/s -> ~38 GB/s of DRAM traffic, i.e. -40..-50%. The mechanism by which this should raise the FPGA's rate [I]: the PCIe read engine has a fixed number of
outstanding requests, so a higher memory latency under load directly lowers bandwidth (bytes = outstanding x size / latency). The measured hogs (-> 8.49 GB/s at 12 hogs) are consistent with this.
For snappy input, B is smaller than the decoded output, so the copy share of traffic is lower and the relative benefit is smaller (but the decoder is the limit there anyway; see memory `bloom_decoder_bound`).
Option E (NT copy) saves the RFO and L3 pollution only: 6.0 -> ~5.0 B.

## 7. Smallest confirming experiment (throwaway, do not merge)

Goal: same benchmark, same query, zero pread after the first touch, buffers kept alive. If the busy-rate at 16/32 threads goes from ~9.7 toward 12.6, the copy is the limiter.

**Why a keep-alive map and not "just skip the read"** [I]: the buffers are freed per group (`oasis_scan.cpp:754`), and jemalloc may hand the bytes to an output buffer in between
(`dirty_decay_ms=0`, large allocs best-fit by address, no guarantee). So skipping the pread would feed the decoder garbage (parser hangs; see memory `hw_run_hang_wedges_device`).
Holding the buffer in a static map guarantees contents are unchanged.

Sketch, all in `extension/src/coalesced_fetcher.cpp` (gated by `getenv("OASIS_EXP_CHUNK_CACHE")`):
```cpp
// file scope; intentionally leaked so no BufferDeleter runs after the pool is destroyed
struct ExpKey { std::string path; uint64_t off, size; bool operator==(const ExpKey&) const = default; };
struct ExpHash { size_t operator()(const ExpKey&k) const { return std::hash<std::string>()(k.path) ^ (k.off*0x9E3779B97F4A7C15ull) ^ k.size; } };
static auto &exp_map = *new std::unordered_map<ExpKey, std::shared_ptr<libstf::Buffer>, ExpHash>();
static auto &exp_mu  = *new std::mutex();
static const bool exp_on = getenv("OASIS_EXP_CHUNK_CACHE") != nullptr;

// PrepareReads(), in the per-merged loop (line 78), before allocate():
if (exp_on) { std::lock_guard g(exp_mu);
    auto it = exp_map.find({file_handle.path, m.offset, m.size});
    if (it != exp_map.end()) { m.buffer = it->second; m.cached = true; total_fetched += m.size; continue; } }
// ExecuteMergedRead(), line 97:
if (m.cached) return;
file_handle.Read(m.buffer->ptr, m.size, m.offset);
if (exp_on) { std::lock_guard g(exp_mu); exp_map.emplace(ExpKey{file_handle.path, m.offset, m.size}, m.buffer); }
```
plus `bool cached=false;` in `MergedRead` (`include/coalesced_fetcher.hpp:93`). The bloom build side (`oasis_hardware_bloom.cpp:390`) goes through the same class.

Run (when you choose to; not run by me): `extension/bench/bench.py` single point at 2^24 and 2^26 probe rows (0.4 and 1.5 GiB of pool; 2^26 stays well under 8 GiB), with and without
`OASIS_EXP_CHUNK_CACHE=1`, `threads` in {4, 16, 32}, bloom off. Compare `read_ns` (should go ~0), perf `pread64` share (should vanish), decoder busy-rate, and wall.
Keep the first (warmup) iterations; they populate the map. Correctness: the bench's expected sums must still match.

Predictions: if the copy is the limiter, 16/32-thread rate rises by roughly the hog-recovery amount (toward 12 GB/s) and 1-4 thread rate is unchanged (already 12.6).
If nothing moves, the drop at 16-32 threads comes from consumer-side traffic (output reads, DuckDB operators), not the copy, and A/C will not help much.
Optional extra control: repeat with 12 memcpy hogs to see whether the hog penalty also shrinks (it should shrink only if the copy was the dominant victim-aggressor).

## 8. What I could not verify
- Kernel 6.8 `mm/gup.c` rules for FOLL_LONGTERM|FOLL_WRITE on ext4 and hugetlbfs (sources not on host; statements are from memory of the kernel).
- That hugetlbfs `userMap` works on the card (needs a hardware smoke test), and the exact built TLB parameters of the loaded bitstream (CMake defaults assumed).
- Zen 2 kernel-copy RFO behaviour and L3/DMA snoop hit rate; the DRAM-traffic table is an accounting model, not a measurement
  (an `amd_df` / perf memory-bandwidth counter run would turn it into data).
- Per-fault cost of the 4 KiB TLB path (estimated only).
- Whether the 3-column probe file's chunk offsets are 64 B aligned (stale-assert question in C.5).
