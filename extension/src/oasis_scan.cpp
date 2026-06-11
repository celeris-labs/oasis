#include "oasis_scan.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/multi_file/multi_file_options.hpp"
#include "duckdb/planner/expression/bound_between_expression.hpp"
#include "duckdb/planner/expression/bound_columnref_expression.hpp"
#include "duckdb/planner/expression/bound_comparison_expression.hpp"
#include "duckdb/planner/expression/bound_conjunction_expression.hpp"
#include "duckdb/planner/expression/bound_constant_expression.hpp"
#include "duckdb/planner/filter/conjunction_filter.hpp"
#include "duckdb/planner/filter/constant_filter.hpp"
#include "duckdb/planner/filter/in_filter.hpp"
#include "duckdb/planner/filter/optional_filter.hpp"
#include "duckdb/planner/operator/logical_get.hpp"
#include "oasis/configuration.hpp"
#include "oasis/oasis_context.hpp"
#include "parcore/configuration.hpp"
#include "parquet_reader.hpp"
#include "parquet_types.h"
#include "thrift_tools.hpp"

namespace duckdb {

static parcore::metadata::Type parquet_type_to_parcore(duckdb_parquet::Type::type t) {
	switch (t) {
	case duckdb_parquet::Type::BOOLEAN:
		return parcore::metadata::Type::BYTE_T;
	case duckdb_parquet::Type::INT32:
        return parcore::metadata::Type::INT32_T;
	case duckdb_parquet::Type::FLOAT:
		return parcore::metadata::Type::FLOAT_T;
	case duckdb_parquet::Type::INT64:
		return parcore::metadata::Type::INT64_T;
	case duckdb_parquet::Type::DOUBLE:
		return parcore::metadata::Type::DOUBLE_T;
	case duckdb_parquet::Type::BYTE_ARRAY:
		return parcore::metadata::Type::BYTE_ARRAY;
	default:
		throw InvalidInputException("Parquet physical type %d not supported by ParCore", (int)t);
	}
}

static parcore::metadata::Compression parquet_codec_to_parcore(duckdb_parquet::CompressionCodec::type c) {
	switch (c) {
	case duckdb_parquet::CompressionCodec::UNCOMPRESSED:
		return parcore::metadata::Compression::RAW;
	case duckdb_parquet::CompressionCodec::SNAPPY:
		return parcore::metadata::Compression::SNAPPY;
	default:
		throw InvalidInputException("Parquet compression codec %d not supported by ParCore", (int)c);
	}
}

static oasis::FilterComparison filter_comparison_to_oasis(ExpressionType comparison) {
	switch (comparison) {
	case ExpressionType::COMPARE_EQUAL:
		return oasis::FilterComparison::EQUAL;
	case ExpressionType::COMPARE_NOTEQUAL:
		return oasis::FilterComparison::NOT_EQUAL;
	case ExpressionType::COMPARE_GREATERTHAN:
		return oasis::FilterComparison::GREATER;
	case ExpressionType::COMPARE_LESSTHAN:
		return oasis::FilterComparison::LOWER;
	case ExpressionType::COMPARE_GREATERTHANOREQUALTO:
		return oasis::FilterComparison::GREATER_EQUAL;
	case ExpressionType::COMPARE_LESSTHANOREQUALTO:
		return oasis::FilterComparison::LOWER_EQUAL;
	default:
		throw InvalidInputException("Oasis hardware filter does not support comparison type %d", (int)comparison);
	}
}

static uint64_t filter_constant_to_rhs(const Value &constant) {
	if (constant.IsNull()) {
		throw InvalidInputException("Oasis hardware filtering does not support NULL constants");
	}
	return static_cast<uint64_t>(constant.DefaultCastAs(LogicalType::BIGINT).GetValue<int64_t>());
}

static OasisFilter translate_equality_list(const vector<Value> &values) {
	constexpr size_t MAX_LIST_VALUES =
	    oasis::FilterConfig::NUM_RHS + oasis::FilterConfig::NUM_ADDITIONAL_RHS;
	if (values.size() < 2 || values.size() > MAX_LIST_VALUES) {
		throw InvalidInputException("Oasis hardware IN filtering supports between 2 and %llu values",
		                            static_cast<unsigned long long>(MAX_LIST_VALUES));
	}

	OasisFilter result;
	result.configured = true;
	result.comparison = values.size() == oasis::FilterConfig::NUM_RHS
	                        ? oasis::FilterComparison::ONE_OF
	                        : oasis::FilterComparison::IN_LIST;

	for (size_t i = 0; i < values.size(); i++) {
		auto rhs = filter_constant_to_rhs(values[i]);
		if (i < oasis::FilterConfig::NUM_RHS) {
			result.rhs[i] = rhs;
		} else {
			const auto additional_index = i - oasis::FilterConfig::NUM_RHS;
			result.additional_rhs[additional_index] = rhs;
			result.additional_rhs_mask |= uint8_t {1} << additional_index;
		}
	}
	return result;
}

static OasisFilter translate_composite_filter(const TableFilter &filter) {
	switch (filter.filter_type) {
	case TableFilterType::CONJUNCTION_AND: {
		auto &conjunction = filter.Cast<ConjunctionAndFilter>();
		if (conjunction.child_filters.size() != 2) {
			break;
		}

		const ConstantFilter *lower = nullptr;
		const ConstantFilter *upper = nullptr;
		for (const auto &child : conjunction.child_filters) {
			if (child->filter_type != TableFilterType::CONSTANT_COMPARISON) {
				break;
			}
			auto &constant = child->Cast<ConstantFilter>();
			if (constant.comparison_type == ExpressionType::COMPARE_GREATERTHANOREQUALTO) {
				lower = &constant;
			} else if (constant.comparison_type == ExpressionType::COMPARE_LESSTHAN ||
			           constant.comparison_type == ExpressionType::COMPARE_LESSTHANOREQUALTO) {
				upper = &constant;
			}
		}

		if (lower && upper) {
			auto comparison = upper->comparison_type == ExpressionType::COMPARE_LESSTHAN
			                      ? oasis::FilterComparison::IN_RANGE
			                      : oasis::FilterComparison::IN_BETWEEN;
			return {true,
			        comparison,
			        {filter_constant_to_rhs(lower->constant), filter_constant_to_rhs(upper->constant)}};
		}
		break;
	}
	case TableFilterType::CONJUNCTION_OR: {
		auto &conjunction = filter.Cast<ConjunctionOrFilter>();
		if (conjunction.child_filters.size() < 2 ||
		    conjunction.child_filters.size() >
		        oasis::FilterConfig::NUM_RHS + oasis::FilterConfig::NUM_ADDITIONAL_RHS) {
			break;
		}

		vector<Value> values;
		for (const auto &child : conjunction.child_filters) {
			if (child->filter_type != TableFilterType::CONSTANT_COMPARISON) {
				break;
			}
			auto &constant = child->Cast<ConstantFilter>();
			if (constant.comparison_type != ExpressionType::COMPARE_EQUAL) {
				break;
			}
			values.push_back(constant.constant);
			if (values.size() == conjunction.child_filters.size()) {
				return translate_equality_list(values);
			}
		}
		break;
	}
	case TableFilterType::IN_FILTER: {
		auto &in_filter = filter.Cast<InFilter>();
		return translate_equality_list(in_filter.values);
	}
	case TableFilterType::OPTIONAL_FILTER: {
		auto &optional_filter = filter.Cast<OptionalFilter>();
		if (optional_filter.child_filter) {
			return translate_composite_filter(*optional_filter.child_filter);
		}
		break;
	}
	default:
		break;
	}

	throw InvalidInputException(
	    "Oasis hardware filtering supports bounded ranges and equality lists with up to eight values");
}

static OasisFilter translate_filter(const TableFilter &filter) {
	if (filter.filter_type == TableFilterType::CONSTANT_COMPARISON) {
		auto &constant_filter = filter.Cast<ConstantFilter>();
		return {true,
		        filter_comparison_to_oasis(constant_filter.comparison_type),
		        {filter_constant_to_rhs(constant_filter.constant), 0}};
	}
	return translate_composite_filter(filter);
}

static void configure_filters(oasis::FilterConfig &filter_config,
                              const vector<libstf::stream_t> &stream_ids,
                              const vector<vector<OasisFilter>> &layers) {
	vector<oasis::FilterConfig::Stream> streams;
	vector<oasis::FilterConfig::Predicate> predicates;
	vector<oasis::FilterConfig::AdditionalRhs> additional_rhs;

	for (size_t output_index = 0; output_index < stream_ids.size(); output_index++) {
		streams.push_back({stream_ids[output_index], libstf::type_t::INT64_T, true});
	}

	for (size_t layer = 0; layer < layers.size(); layer++) {
		for (size_t output_index = 0; output_index < stream_ids.size(); output_index++) {
			const auto stream = stream_ids[output_index];
			const auto &filter = layers[layer][output_index];
			if (!filter.configured) {
				continue;
			}

			predicates.push_back({stream, layer, filter.comparison, filter.rhs});

			if (filter.additional_rhs_mask != 0) {
				if (stream != 0) {
					throw InternalException("Oasis additional RHS predicate was not assigned to stream 0");
				}
				additional_rhs.push_back(
				    {layer, filter.additional_rhs, filter.additional_rhs_mask});
			}
		}
	}

	filter_config.configure(streams, predicates, additional_rhs);
}

static bool get_bound_column_id(const Expression &expr, const LogicalGet &get, idx_t &column_id) {
	if (expr.GetExpressionClass() != ExpressionClass::BOUND_COLUMN_REF) {
		return false;
	}
	auto &column_ref = expr.Cast<BoundColumnRefExpression>();
	if (column_ref.depth != 0 || column_ref.binding.table_index != get.table_index) {
		return false;
	}
	const auto &column_ids = get.GetColumnIds();
	if (column_ref.binding.column_index >= column_ids.size()) {
		return false;
	}
	column_id = column_ids[column_ref.binding.column_index].GetPrimaryIndex();
	return true;
}

struct BoundFilterLeaf {
	idx_t column_id;
	ExpressionType comparison;
	Value constant;
};

static bool translate_bound_comparison(const Expression &expr, const LogicalGet &get,
                                       BoundFilterLeaf &result) {
	if (expr.GetExpressionClass() != ExpressionClass::BOUND_COMPARISON) {
		return false;
	}

	auto &comparison = expr.Cast<BoundComparisonExpression>();
	const BoundConstantExpression *constant = nullptr;
	if (get_bound_column_id(*comparison.left, get, result.column_id) &&
	    comparison.right->GetExpressionClass() == ExpressionClass::BOUND_CONSTANT) {
		constant = &comparison.right->Cast<BoundConstantExpression>();
		result.comparison = comparison.GetExpressionType();
	} else if (get_bound_column_id(*comparison.right, get, result.column_id) &&
	           comparison.left->GetExpressionClass() == ExpressionClass::BOUND_CONSTANT) {
		constant = &comparison.left->Cast<BoundConstantExpression>();
		result.comparison = FlipComparisonExpression(comparison.GetExpressionType());
	} else {
		return false;
	}

	switch (result.comparison) {
	case ExpressionType::COMPARE_EQUAL:
	case ExpressionType::COMPARE_NOTEQUAL:
	case ExpressionType::COMPARE_GREATERTHAN:
	case ExpressionType::COMPARE_LESSTHAN:
	case ExpressionType::COMPARE_GREATERTHANOREQUALTO:
	case ExpressionType::COMPARE_LESSTHANOREQUALTO:
		break;
	default:
		return false;
	}
	if (constant->value.IsNull()) {
		return false;
	}
	result.constant = constant->value;
	return true;
}

static void flatten_and_branch(const Expression &expr, vector<reference<const Expression>> &leaves) {
	if (expr.GetExpressionClass() == ExpressionClass::BOUND_CONJUNCTION &&
	    expr.GetExpressionType() == ExpressionType::CONJUNCTION_AND) {
		auto &conjunction = expr.Cast<BoundConjunctionExpression>();
		for (const auto &child : conjunction.children) {
			flatten_and_branch(*child, leaves);
		}
		return;
	}
	leaves.push_back(expr);
}

static bool translate_bound_branch(const Expression &expr, const LogicalGet &get,
                                   vector<OasisLayerPredicate> &predicates) {
	vector<reference<const Expression>> leaves;
	flatten_and_branch(expr, leaves);
	map<idx_t, vector<BoundFilterLeaf>> column_filters;

	for (const auto &leaf_ref : leaves) {
		const auto &leaf = leaf_ref.get();
		if (leaf.GetExpressionClass() == ExpressionClass::BOUND_BETWEEN) {
			auto &between = leaf.Cast<BoundBetweenExpression>();
			idx_t column_id;
			if (!between.lower_inclusive || !get_bound_column_id(*between.input, get, column_id) ||
			    between.lower->GetExpressionClass() != ExpressionClass::BOUND_CONSTANT ||
			    between.upper->GetExpressionClass() != ExpressionClass::BOUND_CONSTANT) {
				return false;
			}
			auto &lower = between.lower->Cast<BoundConstantExpression>();
			auto &upper = between.upper->Cast<BoundConstantExpression>();
			if (lower.value.IsNull() || upper.value.IsNull()) {
				return false;
			}
			OasisFilter filter;
			filter.configured = true;
			filter.comparison = between.upper_inclusive ? oasis::FilterComparison::IN_BETWEEN
			                                            : oasis::FilterComparison::IN_RANGE;
			filter.rhs = {filter_constant_to_rhs(lower.value), filter_constant_to_rhs(upper.value)};
			predicates.push_back({column_id, filter});
			continue;
		}

		BoundFilterLeaf translated;
		if (!translate_bound_comparison(leaf, get, translated)) {
			return false;
		}
		column_filters[translated.column_id].push_back(std::move(translated));
	}

	for (auto &entry : column_filters) {
		auto &filters = entry.second;
		if (filters.size() == 1) {
			OasisFilter filter;
			filter.configured = true;
			filter.comparison = filter_comparison_to_oasis(filters[0].comparison);
			filter.rhs[0] = filter_constant_to_rhs(filters[0].constant);
			predicates.push_back({entry.first, filter});
			continue;
		}
		if (filters.size() != 2) {
			return false;
		}

		const BoundFilterLeaf *lower = nullptr;
		const BoundFilterLeaf *upper = nullptr;
		for (const auto &filter : filters) {
			if (filter.comparison == ExpressionType::COMPARE_GREATERTHANOREQUALTO) {
				lower = &filter;
			} else if (filter.comparison == ExpressionType::COMPARE_LESSTHAN ||
			           filter.comparison == ExpressionType::COMPARE_LESSTHANOREQUALTO) {
				upper = &filter;
			}
		}
		if (!lower || !upper) {
			return false;
		}

		OasisFilter filter;
		filter.configured = true;
		filter.comparison = upper->comparison == ExpressionType::COMPARE_LESSTHAN
		                        ? oasis::FilterComparison::IN_RANGE
		                        : oasis::FilterComparison::IN_BETWEEN;
		filter.rhs = {filter_constant_to_rhs(lower->constant),
		              filter_constant_to_rhs(upper->constant)};
		predicates.push_back({entry.first, filter});
	}
	return !predicates.empty();
}

void OasisPushdownComplexFilter(ClientContext &context, LogicalGet &get, FunctionData *bind_data_p,
                                vector<unique_ptr<Expression>> &filters) {
	(void)context;
	if (filters.size() != 1 || filters[0]->GetExpressionClass() != ExpressionClass::BOUND_CONJUNCTION ||
	    filters[0]->GetExpressionType() != ExpressionType::CONJUNCTION_OR) {
		return;
	}

	auto &conjunction = filters[0]->Cast<BoundConjunctionExpression>();
	if (conjunction.children.size() < 2 ||
	    conjunction.children.size() > oasis::FilterConfig::NUM_LAYERS) {
		return;
	}

	vector<vector<OasisLayerPredicate>> layers;
	for (const auto &branch : conjunction.children) {
		vector<OasisLayerPredicate> predicates;
		if (!translate_bound_branch(*branch, get, predicates)) {
			return;
		}
		layers.push_back(std::move(predicates));
	}

	auto &bind_data = bind_data_p->Cast<OasisScanBindData>();
	bind_data.filter_layers = std::move(layers);
	filters.clear();
}

static parcore::metadata::Metadata build_parcore_metadata(ClientContext &context, ParquetReader &parquet_reader) {
	auto *file_meta = parquet_reader.GetFileMetadata();
	auto &file_handle = parquet_reader.GetHandle();

    // TODO: Remove the fetching of page meta data after adding a page header parser to the hardware
	auto proto = duckdb_base_std::make_shared<ThriftFileTransport>(file_handle, false);
	auto thrift_proto =
	    make_uniq<duckdb_apache::thrift::protocol::TCompactProtocolT<ThriftFileTransport>>(proto);

	parcore::metadata::Metadata meta;

	for (auto &col : parquet_reader.columns) {
		meta.column_names.push_back(col.name);
	}

	for (auto &rg : file_meta->row_groups) {
		parcore::metadata::RowGroup parcore_rg;

		for (auto &col_chunk : rg.columns) {
			auto &cmd = col_chunk.meta_data;

			parcore::metadata::ColumnChunk parcore_cc;
			parcore_cc.type = parquet_type_to_parcore(cmd.type);
			parcore_cc.num_values = static_cast<uint64_t>(cmd.num_values);
			parcore_cc.compression = parquet_codec_to_parcore(cmd.codec);

			// Walk page headers to collect individual pages
			int64_t start_offset =
			    cmd.__isset.dictionary_page_offset ? cmd.dictionary_page_offset : cmd.data_page_offset;
			int64_t end_offset = start_offset + cmd.total_compressed_size;

			proto->SetLocation(static_cast<idx_t>(start_offset));

			uint64_t hybrid_num_values = 0;

			while (proto->GetLocation() < static_cast<idx_t>(end_offset)) {
				idx_t page_header_start = proto->GetLocation();

				duckdb_parquet::PageHeader page_hdr;
				page_hdr.read(thrift_proto.get());

				idx_t page_data_offset = proto->GetLocation();
				uint64_t page_size = static_cast<uint64_t>(page_hdr.compressed_page_size);

				parcore::metadata::Page parcore_page;
				parcore_page.offset = page_data_offset;
				parcore_page.size = page_size;

				if (page_hdr.type == duckdb_parquet::PageType::DICTIONARY_PAGE) {
					parcore_page.encoding = parcore::metadata::Encoding::PLAIN;
					parcore_page.num_values =
					    static_cast<uint64_t>(page_hdr.dictionary_page_header.num_values);
					parcore_cc.dictionary = parcore_page;
				} else if (page_hdr.type == duckdb_parquet::PageType::DATA_PAGE) {
					auto enc = page_hdr.data_page_header.encoding;
					if (enc == duckdb_parquet::Encoding::RLE_DICTIONARY ||
					    enc == duckdb_parquet::Encoding::PLAIN_DICTIONARY) {
						parcore_page.encoding = parcore::metadata::Encoding::HYBRID;
						parcore_page.num_values =
						    static_cast<uint64_t>(page_hdr.data_page_header.num_values);
						hybrid_num_values += parcore_page.num_values;
					} else {
						parcore_page.encoding = parcore::metadata::Encoding::PLAIN;
						parcore_page.num_values =
						    static_cast<uint64_t>(page_hdr.data_page_header.num_values);
					}
					parcore_cc.data.push_back(parcore_page);
				} else if (page_hdr.type == duckdb_parquet::PageType::DATA_PAGE_V2) {
					auto enc = page_hdr.data_page_header_v2.encoding;
					if (enc == duckdb_parquet::Encoding::RLE_DICTIONARY ||
					    enc == duckdb_parquet::Encoding::PLAIN_DICTIONARY) {
						parcore_page.encoding = parcore::metadata::Encoding::HYBRID;
						parcore_page.num_values =
						    static_cast<uint64_t>(page_hdr.data_page_header_v2.num_values);
						hybrid_num_values += parcore_page.num_values;
					} else {
						parcore_page.encoding = parcore::metadata::Encoding::PLAIN;
						parcore_page.num_values =
						    static_cast<uint64_t>(page_hdr.data_page_header_v2.num_values);
					}
					parcore_cc.data.push_back(parcore_page);
				}

				proto->SetLocation(page_data_offset + page_size);
			}

			parcore_cc.hybrid_num_values = hybrid_num_values;
			parcore_rg.chunks.push_back(std::move(parcore_cc));
		}

		meta.groups.push_back(std::move(parcore_rg));
	}

	return meta;
}

unique_ptr<FunctionData> OasisScanBind(ClientContext &context, TableFunctionBindInput &input,
                                       vector<LogicalType> &return_types, vector<string> &names) {
	auto parquet_file = StringValue::Get(input.inputs[0]);

	ParquetOptions parquet_opts(context);
	ParquetReader parquet_reader(context, OpenFileInfo {parquet_file}, parquet_opts);

	auto bind_data = make_uniq<OasisScanBindData>();

	for (auto &col : parquet_reader.columns) {
		names.push_back(col.name);
		return_types.push_back(col.type);
	}

	auto meta = build_parcore_metadata(context, parquet_reader);
	if (meta.groups.empty()) {
		throw InvalidInputException("Parquet file contains no row groups");
	}
	bind_data->metadata = std::move(meta);
	bind_data->filename = parquet_file;

	return std::move(bind_data);
}

unique_ptr<GlobalTableFunctionState> OasisScanInitGlobal(ClientContext &context, TableFunctionInitInput &input) {
	auto &bind_data = input.bind_data->Cast<OasisScanBindData>();

	// Ensure OasisContext is initialized for this database instance.
	ObjectCache::GetObjectCache(context).GetOrCreate<OasisContextCacheEntry>("oasis_context");
	auto &ctx = oasis::OasisContext::ctx();

	auto gstate = make_uniq<OasisScanGlobalState>();

	auto column_chunk_config = ctx.config<parcore::ColumnChunkDecoderConfig>();
	auto page_config = ctx.config<parcore::PageDecoderConfig>();

	auto maybe_file = arrow::io::ReadableFile::Open(bind_data.filename);
	if (!maybe_file.ok()) {
		throw IOException(maybe_file.status().ToString());
	}
	gstate->file = *maybe_file;

	gstate->total_groups = bind_data.metadata.groups.size();

	for (auto col_id : input.column_ids) {
		if (col_id == COLUMN_IDENTIFIER_ROW_ID) {
			continue;
		}
		auto t = bind_data.metadata.groups[0].chunks[col_id].type;
		if (!parcore::metadata::is_libstf_type(t)) {
			throw InvalidInputException("Column '%s' has type BYTE_ARRAY which is not supported by ParCore",
			                            bind_data.metadata.column_names[col_id].c_str());
		}
		gstate->column_ids.push_back(col_id);
	}

	if (gstate->column_ids.empty() || gstate->column_ids.size() > oasis::FilterConfig::MAX_STREAMS) {
		throw InvalidInputException("Oasis hardware filtering supports between one and four projected columns");
	}
	for (const auto col_id : gstate->column_ids) {
		if (bind_data.metadata.groups[0].chunks[col_id].type != parcore::metadata::Type::INT64_T) {
			throw InvalidInputException("Oasis hardware filtering currently supports only INT64 columns");
		}
	}

	const bool no_filters = !input.filters || input.filters->filters.empty();
	const bool has_layer_filters = !bind_data.filter_layers.empty();
	if (has_layer_filters && !no_filters) {
		throw InternalException("Oasis received both complex and table filter pushdown");
	}
	if (!has_layer_filters && !no_filters &&
	    input.filters->filters.size() != gstate->column_ids.size()) {
		throw InvalidInputException(
		    "Oasis multi-column filtering currently requires one predicate for every projected column");
	}

	vector<vector<OasisFilter>> layers;
	optional_idx additional_rhs_column;

	if (has_layer_filters) {
		layers.resize(bind_data.filter_layers.size(),
		              vector<OasisFilter>(gstate->column_ids.size()));
		for (size_t layer = 0; layer < bind_data.filter_layers.size(); layer++) {
			for (const auto &predicate : bind_data.filter_layers[layer]) {
				auto output_it =
				    std::find(gstate->column_ids.begin(), gstate->column_ids.end(),
				              predicate.column_id);
				if (output_it == gstate->column_ids.end()) {
					throw InvalidInputException(
					    "Oasis hardware filter column %llu is not available in the scan",
					    static_cast<unsigned long long>(predicate.column_id));
				}
				const auto output_index =
				    static_cast<size_t>(output_it - gstate->column_ids.begin());
				if (layers[layer][output_index].configured) {
					throw InvalidInputException(
					    "Oasis hardware supports one predicate per column in each OR branch");
				}
				layers[layer][output_index] = predicate.filter;
				if (predicate.filter.additional_rhs_mask != 0) {
					if (additional_rhs_column.IsValid() &&
					    additional_rhs_column.GetIndex() != output_index) {
						throw InvalidInputException(
						    "Oasis additional RHS values must use the same column across all layers");
					}
					additional_rhs_column = output_index;
				}
			}
		}
	} else if (no_filters) {
		layers.resize(1, vector<OasisFilter>(gstate->column_ids.size()));
		for (auto &filter : layers[0]) {
			filter.configured = true;
			filter.comparison = oasis::FilterComparison::ALWAYS_TRUE;
		}
	} else {
		layers.resize(1, vector<OasisFilter>(gstate->column_ids.size()));
		vector<bool> has_filter(gstate->column_ids.size(), false);
		for (const auto &filter_entry : input.filters->filters) {
			const auto column_index = filter_entry.first;
			if (column_index >= gstate->column_ids.size()) {
				throw InternalException("Oasis filter column index is out of range");
			}

			auto translated = translate_filter(*filter_entry.second);
			if (translated.additional_rhs_mask != 0) {
				if (additional_rhs_column.IsValid()) {
					throw InvalidInputException(
					    "Oasis hardware supports an IN list on only one column per filter layer");
				}
				additional_rhs_column = column_index;
			}
			layers[0][column_index] = translated;
			has_filter[column_index] = true;
		}

		for (const auto configured : has_filter) {
			if (!configured) {
				throw InvalidInputException(
				    "Oasis multi-column filtering currently requires one predicate for every projected column");
			}
		}
	}

	gstate->stream_ids.resize(gstate->column_ids.size());
	size_t next_stream = 0;
	if (additional_rhs_column.IsValid()) {
		gstate->stream_ids[additional_rhs_column.GetIndex()] = next_stream++;
	}
	for (size_t output_index = 0; output_index < gstate->column_ids.size(); output_index++) {
		if (additional_rhs_column.IsValid() && output_index == additional_rhs_column.GetIndex()) {
			continue;
		}
		gstate->stream_ids[output_index] = next_stream++;
	}

	auto filter_config = ctx.config<oasis::FilterConfig>();
	configure_filters(*filter_config, gstate->stream_ids, layers);

	for (size_t output_index = 0; output_index < gstate->column_ids.size(); output_index++) {
		auto decoder = std::make_shared<parcore::ColumnChunkDecoder>(
		    ctx.cthread(), ctx.tlb_manager(), ctx.output_buffer_manager(),
		    column_chunk_config, page_config, gstate->stream_ids[output_index]);
		gstate->decoders.push_back(decoder);
		gstate->readers.push_back(std::make_unique<parcore::FileReader>(
		    decoder, ctx.memory_pool(), bind_data.metadata, gstate->file));
	}

	gstate->current_buffers.assign(gstate->column_ids.size(), {});
	gstate->current_buf_idx = 0;
	gstate->current_buf_offset = 0;

	return std::move(gstate);
}

unique_ptr<LocalTableFunctionState> OasisScanInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                       GlobalTableFunctionState *global_state_p) {
	return make_uniq<OasisScanLocalState>();
}

// Zero-copy multi-column scan. For each row group we enqueue every column,
// then dequeue them in order (ParCore's output queue is a FIFO) and slice each
// column's buffers in lockstep into STANDARD_VECTOR_SIZE-sized vectors. This
// assumes ParCore returns the same buffer layout (same buffer count, same
// elements per buffer at each index) across all columns of a row group; we
// assert this below.
void OasisScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();
	auto &bind = data_p.bind_data->Cast<OasisScanBindData>();

	// Pull in next row group cursor reached end, needs to be synchronised across columns
	// assuming row groups have same element count across columns
	if (gstate.current_buf_idx >= gstate.current_buffers[0].size()) {
		if (gstate.next_group >= gstate.total_groups) {
			output.SetCardinality(0);
			return;
		}

		for (size_t i = 0; i < gstate.column_ids.size(); i++) {
			gstate.readers[i]->enqueue_column_chunk(gstate.next_group, gstate.column_ids[i]);
		}
		for (size_t i = 0; i < gstate.column_ids.size(); i++) {
			gstate.current_buffers[i] = gstate.readers[i]->next_column_chunk(); // blocks on FPGA
		}

		gstate.current_buf_idx = 0;
		gstate.current_buf_offset = 0;
		gstate.next_group++;
	}

	auto elem_size = [&](size_t col_file_idx) -> size_t {
		// next_group has already been incremented, so the in-flight group is next_group - 1.
		auto t = bind.metadata.groups[gstate.next_group - 1].chunks[col_file_idx].type;
		if (!parcore::metadata::is_libstf_type(t)) {
			throw InternalException("Unsupported ParCore type %d in elem_size", (int)t);
		}
		return libstf::size_of(parcore::metadata::to_libstf_type(t));
	};

	size_t const col0_file_idx = gstate.column_ids[0];
	size_t const total_elements =
	    gstate.current_buffers[0][gstate.current_buf_idx]->size / elem_size(col0_file_idx);
	size_t const remaining_elements = total_elements - gstate.current_buf_offset;
	size_t const emit = std::min<size_t>(remaining_elements, STANDARD_VECTOR_SIZE);
	for (size_t i = 0; i < gstate.column_ids.size(); i++) {
		const size_t kElemSize = elem_size(gstate.column_ids[i]);

		auto &buf = gstate.current_buffers[i][gstate.current_buf_idx];
		if (buf->size / kElemSize != total_elements) {
			throw InternalException(
			    "ParCore buffer layout mismatch across columns: column %llu has %llu elements, expected %llu",
			    (unsigned long long)i, (unsigned long long)(buf->size / kElemSize), (unsigned long long)total_elements);
		}

		// The actual zero-copy handoff. Two things happen here:
		//
		//  1. FlatVector::SetData points the vector's raw data pointer directly
		//     into the FPGA-written libstf buffer (+ byte offset for the
		//     STANDARD_VECTOR_SIZE slice we're emitting this call). No memcpy,
		//     no arrow intermediary.
		//
		//  2. SetAuxiliary hands the buffer's shared_ptr to DuckDB's Vector
		//     lifetime slot (wrapped in LibstfBufferVectorBuffer, because
		//     DuckDB's slot is typed to shared_ptr<VectorBuffer>, not our
		//     shared_ptr<libstf::Buffer>). DuckDB copies this shared_ptr whenever
		//     it copies the vector, so the underlying memory stays alive as long
		//     as any downstream consumer references it.
		//
		// Two refcount holders protect the memory while it's in flight:
		//   - gstate.current_buffers keeps it alive across scan calls while we
		//     slice one FPGA chunk into multiple STANDARD_VECTOR_SIZE emissions
		//     (auxiliary gets cleared on each output.Reset()).
		//   - vector auxiliary (set here) keeps it alive for any downstream
		//     consumer that holds onto the vector past our next scan call.
		auto &vec = output.data[i];
		vec.SetVectorType(VectorType::FLAT_VECTOR);
		FlatVector::SetData(vec, reinterpret_cast<data_ptr_t>(buf->ptr) + gstate.current_buf_offset * kElemSize);
		vec.SetAuxiliary(make_buffer<LibstfBufferVectorBuffer>(buf));
	}

	// Advance the cursor. If we hit the end of this buffer, step to the next
	// one so the next scan call's `if` branch either keeps emitting or pulls
	// a fresh chunk.
	gstate.current_buf_offset += emit;
	if (gstate.current_buf_offset >= total_elements) {
		gstate.current_buf_idx++;
		gstate.current_buf_offset = 0;
	}

	output.SetCardinality(emit);
}

} // namespace duckdb
