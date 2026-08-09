#pragma once

#include "celeris/celeris_context.hpp"
#include "syslog_undef.hpp" // must follow the celeris include, precede the duckdb ones

#include "duckdb/common/types/string_type.hpp"
#include "libstf/buffer.hpp"

#include <cstdint>
#include <memory>
#include <vector>

namespace duckdb {

static constexpr uint64_t REGEX_FPGA_RAW_BATCH_LIMIT = 1ULL << 20; // 1 MiB non-inlined payload per FPGA batch
static constexpr uint64_t REGEX_FPGA_BEAT_BYTES = 64;
static constexpr idx_t REGEX_FPGA_MAX_ACCUM_COUNT = 1ULL << 16; // safety cap when strings are mostly inlined

static_assert(sizeof(string_t) == 16, "duckdb string_t must match the FPGA wire format");

void EnsureCelerisContext();
celeris::CelerisContext &GetCelerisContext();

uint64_t RegexFpgaNonInlinedRawCost(const string_t &input);
uint64_t align_to_64_multiple(uint64_t tight_nonlin_size);

void RegexFpgaPackString(string_t *descriptor, char *raw_base, uint64_t raw_off, const string_t &input);

std::vector<bool> RunFpgaRegexPackedBatch(celeris::CelerisContext &ctx, void *struct_ptr, idx_t count, void *raw_ptr,
                                          uint64_t raw_used, const std::vector<uint8_t> &regex_blob);

std::vector<bool> RunFpgaRegexBatch(celeris::CelerisContext &ctx, const std::vector<string_t> &inputs,
                                    const std::vector<uint8_t> &regex_blob);

} // namespace duckdb
