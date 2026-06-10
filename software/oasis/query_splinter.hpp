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
 * One indivisible unit of work for a single stream: A splinter of a query plan whose operator chain
 * runs source(s) -> operator(s) -> sink. We schedule whole splinters.
 */
class QuerySplinter {
  public:
    std::vector<std::unique_ptr<Operator>> operators;

    [[nodiscard]] HostBufferSinkOperator &sink() {
        for (auto &op : operators) {
            if (auto *s = dynamic_cast<HostBufferSinkOperator *>(op.get())) {
                return *s;
            }
        }
        assert(false && "Splinter has no HostBufferSinkOperator");
        __builtin_unreachable();
    }

    void print(std::ostream &os) const {
        os << "QuerySplinter(";
        for (size_t i = 0; i < operators.size(); ++i) {
            if (i > 0) {
                os << " -> ";
            }
            os << *operators[i];
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
