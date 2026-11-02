// The x-amz-rdma-token descriptor shared by the S3 server and its clients.
//
// A token is the 81-character cuObject descriptor, as used by AIStor and versitygw. Its fields are
// fixed-width hex separated by colons:
//
//   <addr:16>:<size:8>:<rkey:8>:<lid:4>:<qpn:6>:<gid present:1>:<gid:32>
//
// The numbers are written most significant digit first and the GID in network byte order. The token
// names no transport: the server serves it over RC if its GID and QPN match a connected QP.
#pragma once

#include <array>
#include <cinttypes>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <optional>
#include <string>
#include <string_view>

namespace oasis_s3 {

constexpr const char *RDMA_TOKEN_HEADER = "x-amz-rdma-token";
constexpr const char *RDMA_REPLY_HEADER = "x-amz-rdma-reply";
constexpr const char *RDMA_BYTES_HEADER = "x-amz-rdma-bytes-transferred";
constexpr const char *RDMA_CONNECT_PATH = "/rdma/connect";

// The largest buffer one token can describe.
constexpr uint64_t RDMA_TOKEN_MAX_LENGTH = UINT32_MAX;

struct RdmaToken {
    uint64_t                addr        = 0;
    uint32_t                length      = 0;
    uint32_t                rkey        = 0;
    uint16_t                lid         = 0;
    uint32_t                qpn         = 0; // 24 bits.
    bool                    gid_present = false;
    std::array<uint8_t, 16> gid         = {}; // All zero unless gid_present.
};

namespace detail {

constexpr size_t TOKEN_CHARS = 81;

inline int hex_value(char c) {
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

// Consumes `width` hex digits and the separator after them, if `separated`.
inline bool take_hex(std::string_view &text, size_t width, bool separated, uint64_t &value) {
    value = 0;
    for (size_t i = 0; i < width; ++i) {
        const int digit = hex_value(text[i]);
        if (digit < 0) {
            return false;
        }
        value = (value << 4) | static_cast<uint64_t>(digit);
    }
    if (separated && text[width] != ':') {
        return false;
    }
    text.remove_prefix(width + (separated ? 1 : 0));
    return true;
}

} // namespace detail

inline std::string format_token(const RdmaToken &token) {
    char text[detail::TOKEN_CHARS + 1];
    int  used = std::snprintf(text, sizeof(text), "%016" PRIx64 ":%08" PRIx32 ":%08" PRIx32 ":%04" PRIx16
                                                  ":%06" PRIx32 ":%d:",
                              token.addr, token.length, token.rkey, token.lid, token.qpn,
                              token.gid_present ? 1 : 0);
    for (const uint8_t byte : token.gid) {
        used += std::snprintf(text + used, sizeof(text) - static_cast<size_t>(used), "%02x", byte);
    }
    return std::string(text, static_cast<size_t>(used));
}

// Returns nullopt unless `text` is exactly one token, so a `:addr:size` suffix is rejected.
inline std::optional<RdmaToken> parse_token(std::string_view text) {
    if (text.size() != detail::TOKEN_CHARS) {
        return std::nullopt;
    }

    uint64_t addr, length, rkey, lid, qpn, gid_present;
    if (!detail::take_hex(text, 16, true, addr) || !detail::take_hex(text, 8, true, length) ||
        !detail::take_hex(text, 8, true, rkey) || !detail::take_hex(text, 4, true, lid) ||
        !detail::take_hex(text, 6, true, qpn) || !detail::take_hex(text, 1, true, gid_present) ||
        gid_present > 1) {
        return std::nullopt;
    }

    RdmaToken token;
    token.addr        = addr;
    token.length      = static_cast<uint32_t>(length);
    token.rkey        = static_cast<uint32_t>(rkey);
    token.lid         = static_cast<uint16_t>(lid);
    token.qpn         = static_cast<uint32_t>(qpn);
    token.gid_present = gid_present == 1;
    for (uint8_t &byte : token.gid) {
        uint64_t value;
        if (!detail::take_hex(text, 2, false, value)) {
            return std::nullopt;
        }
        byte = token.gid_present ? static_cast<uint8_t>(value) : 0;
    }
    return token;
}

} // namespace oasis_s3
