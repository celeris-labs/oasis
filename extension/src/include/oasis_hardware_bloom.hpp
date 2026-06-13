#pragma once

#include "oasis_scan.hpp"

#include <atomic>
#include <memory>
#include <mutex>
#include <vector>

namespace libstf {
class Buffer;
}

namespace duckdb {

struct OasisHardwareBloomState {
        std::atomic<bool> executed {false};

        std::mutex launch_mutex;
        std::mutex consume_mutex;

        std::vector<std::shared_ptr<libstf::Buffer>> buffers;

        size_t current_buffer_idx = 0;
        size_t current_buffer_offset = 0;
};

void InitializeOasisHardwareBloom(ClientContext &context, const OasisScanBindData &probe_bind);

void OasisScanFunctionBloomHardware(ClientContext &context, TableFunctionInput &data_p, DataChunk &output);

} // namespace duckdb