#pragma once

#include "oasis/operator.hpp"

#include <memory>
#include <ostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace oasis {

/**
 * One operator flow: source(s) -> operator(s) -> sink, ending in exactly one LocalSinkOperator.
 * OperatorFlows are mapped onto hardware streams.
 */
using OperatorFlow = std::vector<std::unique_ptr<Operator>>;

/**
 * Capability a hardware stream provides (and a flow requires). DECODE streams run flows that
 * decode column chunks. BYPASS streams have no decoder, so the source writes directly into the
 * sink.
 */
enum class StreamCapability : uint8_t { DECODE = 0, BYPASS = 1 };
constexpr size_t NUM_STREAM_CAPABILITIES = 2;

inline const char *to_string(StreamCapability capability) {
    switch (capability) {
    case StreamCapability::DECODE:
        return "DECODE";
    case StreamCapability::BYPASS:
        return "BYPASS";
    }
    return "UNKNOWN";
}

// The capability the flow's stream must provide. Throws if the flow is malformed for the
// capability it requires.
inline StreamCapability required_capability(const OperatorFlow &flow) {
    for (const auto &op : flow) {
        if (dynamic_cast<const DecodeColumnChunkOperator *>(op.get()) != nullptr) {
            return StreamCapability::DECODE;
        }
    }
    // A flow without a decode operator runs raw source->sink on a bypass stream, which only
    // remote (RDMA) reads can feed.
    for (const auto &op : flow) {
        if (dynamic_cast<const LocalSourceOperator *>(op.get()) != nullptr) {
            throw std::runtime_error(
                "Flow without a decode operator requires a bypass stream, which cannot use a "
                "LocalSourceOperator: only RDMA reads run on bypass streams");
        }
    }
    return StreamCapability::BYPASS;
}

/**
 * One unit of work the scheduler dispatches as a whole: A vector of OperatorFlows, each running on
 * its own hardware stream. The scheduler load-balances the flows across the active hardware streams
 * but completes the whole splinter only once every flow has completed.
 */
class QuerySplinter {
  public:
    std::vector<OperatorFlow> streams;

    [[nodiscard]] size_t num_flows() const { return streams.size(); }

    void print(std::ostream &os) const {
        os << "QuerySplinter(";
        for (size_t u = 0; u < streams.size(); ++u) {
            if (u > 0) {
                os << "; ";
            }
            os << "[";
            for (size_t i = 0; i < streams[u].size(); ++i) {
                if (i > 0) {
                    os << " -> ";
                }
                os << *streams[u][i];
            }
            os << "]";
        }
        os << ")";
    }

    [[nodiscard]] std::string to_string() const {
        std::ostringstream os;
        print(os);
        return os.str();
    }
};

inline std::ostream &operator<<(std::ostream &os, const QuerySplinter &splinter) {
    splinter.print(os);
    return os;
}

} // namespace oasis
