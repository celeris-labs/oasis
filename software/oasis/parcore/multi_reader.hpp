#pragma once

#include <parcore/multi_reader.hpp>

namespace oasis {
namespace parcore {

/* multi_reader.hpp */
using MultiReader = ::parcore::MultiReader;

template <typename T, typename... Args>
static inline std::shared_ptr<MultiReader> make_multi_reader(size_t count,
                                                             Args &&...args) {
  return std::move(::parcore::make_multi_reader<T>(count, args...));
}

} // namespace parcore
} // namespace oasis
