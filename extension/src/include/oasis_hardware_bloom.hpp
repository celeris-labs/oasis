#pragma once

#include "oasis_scan.hpp"
#include "oasis/splinter_result.hpp"

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>

namespace libstf {
class Buffer;
}

namespace duckdb {

struct OasisHardwareBloomState {
        ~OasisHardwareBloomState();

        std::atomic<bool> executed {false};
        std::atomic<bool> tlast_injector_enabled {false};

        std::mutex launch_mutex;
        std::mutex consume_mutex;

        std::optional<oasis::SplinterResultHandle> result;
        std::shared_ptr<libstf::Buffer> current_buffer;

        size_t current_buffer_offset = 0;
        bool result_drained = false;

        uint64_t output_buffers = 0;
        uint64_t output_bytes = 0;
};

void InitializeOasisHardwareBloom(ClientContext &context, const OasisScanBindData &probe_bind);

void OasisScanFunctionBloomHardware(ClientContext &context, TableFunctionInput &data_p, DataChunk &output);

} // namespace duckdb
