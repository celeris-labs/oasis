#pragma once

#include <parcore/multi_reader.hpp>

namespace oasis {
namespace parcore {

/* reader.hpp */
using MultiReader = ::parcore::MultiReader;

template <typename T>
constexpr auto &make_multi_reader = ::parcore::make_multi_reader<T>;

} // namespace parcore
} // namespace oasis
