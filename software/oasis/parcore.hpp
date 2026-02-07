#pragma once

#include <parcore/configuration.hpp>
#include <parcore/metadata/metadata.hpp>
#include <parcore/metadata/utils.hpp>
#include <parcore/reader.hpp>

namespace oasis {
namespace parcore {

/* metadata/metadata.hpp */
using Encoding = ::parcore::metadata::Encoding;
using Compression = ::parcore::metadata::Compression;
using Page = ::parcore::metadata::Page;
using ColumnChunk = ::parcore::metadata::ColumnChunk;
using RowGroup = ::parcore::metadata::RowGroup;
using Metadata = ::parcore::metadata::Metadata;

/* metadata/utils.hpp */
using from_file = ::parcore::metadata::from_file;

/* configuration.hpp */
using PageType = ::parcore::PageType;
using PageDecoderConfig = ::parcore::PageDecoderConfig;

/* reader.hpp */
using Reader = ::parcore::Reader;
using FileReader = ::parcore::FileReader;

} // namespace parcore
} // namespace oasis
