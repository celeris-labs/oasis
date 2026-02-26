#pragma once

#include <parcore/configuration.hpp>
#include <parcore/metadata/metadata.hpp>
#include <parcore/metadata/utils.hpp>

namespace oasis {
namespace parcore {

/* metadata/metadata.hpp */
using Type = ::parcore::metadata::Type;
using Encoding = ::parcore::metadata::Encoding;
using Compression = ::parcore::metadata::Compression;
using Page = ::parcore::metadata::Page;
using ColumnChunk = ::parcore::metadata::ColumnChunk;
using RowGroup = ::parcore::metadata::RowGroup;
using Metadata = ::parcore::metadata::Metadata;

/* metadata/utils.hpp */
constexpr auto &from_file = ::parcore::metadata::from_file;
constexpr auto &is_libstf_type = ::parcore::metadata::is_libstf_type;
constexpr auto &to_libstf_type = ::parcore::metadata::to_libstf_type;

/* configuration.hpp */
using PageType = ::parcore::PageType;
using ColumnChunkDecoderConfig = ::parcore::ColumnChunkDecoderConfig;
using PageDecoderConfig = ::parcore::PageDecoderConfig;

} // namespace parcore
} // namespace oasis
