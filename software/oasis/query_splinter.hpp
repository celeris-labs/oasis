#pragma once

#include "oasis/operator.hpp"

#include <cassert>
#include <memory>
#include <ostream>
#include <sstream>
#include <string>
#include <vector>

namespace oasis {

/**
 * One operator flow: source(s) -> operator(s) -> sink, ending in exactly one LocalSinkOperator. An
 * OperatorFlow is mapped onto a hardware stream.
 */
using OperatorFlow = std::vector<std::unique_ptr<Operator>>;

/**
 * One unit of work the scheduler dispatches as a whole: A vector of OperatorFlows, each running on
 * its own hardware stream. The scheduler load-balances the flows across the active hardware streams
 * but completes the whole splinter only once every flow has completed.
 */
class QuerySplinter {
  public:
    std::vector<OperatorFlow> streams;

    [[nodiscard]] size_t num_flows() const { return streams.size(); }

    // The sink of the given flow. Each OperatorFlow ends in exactly one LocalSinkOperator.
    [[nodiscard]] LocalSinkOperator &sink(size_t flow_idx) {
        for (auto &op : streams[flow_idx]) {
            if (auto *s = dynamic_cast<LocalSinkOperator *>(op.get())) {
                return *s;
            }
        }
        assert(false && "OperatorFlow has no LocalSinkOperator");
        __builtin_unreachable();
    }

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
