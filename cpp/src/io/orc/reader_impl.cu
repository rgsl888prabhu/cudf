/*
 * Copyright (c) 2019-2021, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * @file reader_impl.cu
 * @brief cuDF-IO ORC reader class implementation
 */

#include "io/orc/orc_gpu.h"
#include "reader_impl.hpp"
#include "timezone.cuh"

#include <io/comp/gpuinflate.h>
#include "orc.h"

#include <cudf/table/table.hpp>
#include <cudf/utilities/error.hpp>
#include <cudf/utilities/traits.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_buffer.hpp>
#include <rmm/device_uvector.hpp>
#include <rmm/exec_policy.hpp>

#include <algorithm>
#include <array>

namespace cudf {
namespace io {
namespace detail {
namespace orc {
// Import functionality that's independent of legacy code
using namespace cudf::io::orc;
using namespace cudf::io;

namespace {
/**
 * @brief Function that translates ORC data kind to cuDF type enum
 */
constexpr type_id to_type_id(const orc::SchemaType &schema,
                             bool use_np_dtypes,
                             type_id timestamp_type_id)
{
  switch (schema.kind) {
    case orc::BOOLEAN: return type_id::BOOL8;
    case orc::BYTE: return type_id::INT8;
    case orc::SHORT: return type_id::INT16;
    case orc::INT: return type_id::INT32;
    case orc::LONG: return type_id::INT64;
    case orc::FLOAT: return type_id::FLOAT32;
    case orc::DOUBLE: return type_id::FLOAT64;
    case orc::STRING:
    case orc::BINARY:
    case orc::VARCHAR:
    case orc::CHAR:
      // Variable-length types can all be mapped to STRING
      return type_id::STRING;
    case orc::TIMESTAMP:
      return (timestamp_type_id != type_id::EMPTY) ? timestamp_type_id
                                                   : type_id::TIMESTAMP_NANOSECONDS;
    case orc::DATE:
      // There isn't a (DAYS -> np.dtype) mapping
      return (use_np_dtypes) ? type_id::TIMESTAMP_MILLISECONDS : type_id::TIMESTAMP_DAYS;
    case orc::DECIMAL: return type_id::DECIMAL64;
    case orc::LIST: return type_id::LIST;
    case orc::STRUCT: return type_id::STRUCT;
    default: break;
  }

  return type_id::EMPTY;
}

/**
 * @brief Function that translates cuDF time unit to ORC clock frequency
 */
constexpr int32_t to_clockrate(type_id timestamp_type_id)
{
  switch (timestamp_type_id) {
    case type_id::TIMESTAMP_SECONDS: return 1;
    case type_id::TIMESTAMP_MILLISECONDS: return 1000;
    case type_id::TIMESTAMP_MICROSECONDS: return 1000000;
    case type_id::TIMESTAMP_NANOSECONDS: return 1000000000;
    default: return 0;
  }
}

constexpr std::pair<gpu::StreamIndexType, uint32_t> get_index_type_and_pos(
  const orc::StreamKind kind, uint32_t skip_count, bool non_child)
{
  switch (kind) {
    case orc::DATA:
      skip_count += 1;
      skip_count |= (skip_count & 0xff) << 8;
      return std::make_pair(gpu::CI_DATA, skip_count);
    case orc::LENGTH:
    case orc::SECONDARY:
      skip_count += 1;
      skip_count |= (skip_count & 0xff) << 16;
      return std::make_pair(gpu::CI_DATA2, skip_count);
    case orc::DICTIONARY_DATA: return std::make_pair(gpu::CI_DICTIONARY, skip_count);
    case orc::PRESENT:
      skip_count += (non_child ? 1 : 0);
      return std::make_pair(gpu::CI_PRESENT, skip_count);
    case orc::ROW_INDEX: return std::make_pair(gpu::CI_INDEX, skip_count);
    default:
      // Skip this stream as it's not strictly required
      return std::make_pair(gpu::CI_NUM_STREAMS, 0);
  }
}

}  // namespace

namespace {
/**
 * @brief Struct that maps ORC streams to columns
 */
struct orc_stream_info {
  orc_stream_info() = default;
  explicit orc_stream_info(
    uint64_t offset_, size_t dst_pos_, uint32_t length_, uint32_t gdf_idx_, uint32_t stripe_idx_)
    : offset(offset_),
      dst_pos(dst_pos_),
      length(length_),
      gdf_idx(gdf_idx_),
      stripe_idx(stripe_idx_)
  {
  }
  uint64_t offset;      // offset in file
  size_t dst_pos;       // offset in memory relative to start of compressed stripe data
  size_t length;        // length in file
  uint32_t gdf_idx;     // column index
  uint32_t stripe_idx;  // stripe index
};

/**
 * @brief Function that populates column descriptors stream/chunk
 */
size_t gather_stream_info(const size_t stripe_index,
                          const orc::StripeInformation *stripeinfo,
                          const orc::StripeFooter *stripefooter,
                          const std::vector<int> &orc2gdf,
                          const std::vector<column_meta> &gdf2orc,
                          const std::vector<orc::SchemaType> types,
                          bool use_index,
                          size_t *num_dictionary_entries,
                          hostdevice_vector<gpu::ColumnDesc> &chunks,
                          std::vector<orc_stream_info> &stream_info)
{
  const auto num_columns = gdf2orc.size();
  uint64_t src_offset    = 0;
  uint64_t dst_offset    = 0;
  for (const auto &stream : stripefooter->streams) {
    if (!stream.column_id || *stream.column_id >= orc2gdf.size()) {
      dst_offset += stream.length;
      continue;
    }

    auto const column_id = *stream.column_id;
    auto col             = orc2gdf[column_id];

    if (col == -1) {
      // A struct-type column has no data itself, but rather child columns
      // for each of its fields. There is only a PRESENT stream, which
      // needs to be included for the reader.
      const auto schema_type = types[column_id];
      if (schema_type.subtypes.size() != 0) {
        if (schema_type.kind == orc::STRUCT && stream.kind == orc::PRESENT) {
          for (const auto &idx : schema_type.subtypes) {
            auto child_idx = (idx < orc2gdf.size()) ? orc2gdf[idx] : -1;
            if (child_idx >= 0) {
              col                             = child_idx;
              auto &chunk                     = chunks[stripe_index * num_columns + col];
              chunk.strm_id[gpu::CI_PRESENT]  = stream_info.size();
              chunk.strm_len[gpu::CI_PRESENT] = stream.length;
            }
          }
        }
      }
    }
    if (col != -1) {
      if (src_offset >= stripeinfo->indexLength || use_index) {
        // NOTE: skip_count field is temporarily used to track index ordering
        auto &chunk = chunks[stripe_index * num_columns + col];
        const auto idx =
          get_index_type_and_pos(stream.kind, chunk.skip_count, col == orc2gdf[column_id]);
        if (idx.first < gpu::CI_NUM_STREAMS) {
          chunk.strm_id[idx.first]  = stream_info.size();
          chunk.strm_len[idx.first] = stream.length;
          chunk.skip_count          = idx.second;

          if (idx.first == gpu::CI_DICTIONARY) {
            chunk.dictionary_start = *num_dictionary_entries;
            chunk.dict_len         = stripefooter->columns[column_id].dictionarySize;
            *num_dictionary_entries += stripefooter->columns[column_id].dictionarySize;
          }
        }
      }
      stream_info.emplace_back(
        stripeinfo->offset + src_offset, dst_offset, stream.length, col, stripe_index);
      dst_offset += stream.length;
    }
    src_offset += stream.length;
  }

  return dst_offset;
}

}  // namespace

/**
 * @brief In order to support multiple input files/buffers we need to gather
 * the metadata across all of those input(s). This class provides a place
 * to aggregate that metadata from all the files.
 */
class aggregate_orc_metadata {
  using OrcStripeInfo = std::pair<const StripeInformation *, const StripeFooter *>;

 public:
  mutable std::vector<cudf::io::orc::metadata> per_file_metadata;
  mutable std::vector<cudf::io::orc::metadata::stripe_source_mapping> stripe_source_mappings;
  size_type const num_rows;
  size_type const num_columns;
  size_type const num_stripes;

  /**
   * @brief Create a metadata object from each element in the source vector
   */
  auto metadatas_from_sources(std::vector<std::unique_ptr<datasource>> const &sources)
  {
    std::vector<cudf::io::orc::metadata> metadatas;
    std::transform(
      sources.cbegin(), sources.cend(), std::back_inserter(metadatas), [](auto const &source) {
        return cudf::io::orc::metadata(source.get());
      });
    return metadatas;
  }

  /**
   * @brief Sums up the number of rows of each source
   */
  size_type calc_num_rows() const
  {
    return std::accumulate(
      per_file_metadata.begin(), per_file_metadata.end(), 0, [](auto &sum, auto &pfm) {
        return sum + pfm.get_total_rows();
      });
  }

  /**
   * @brief Number of columns in a ORC file.
   */
  size_type calc_num_cols() const
  {
    if (not per_file_metadata.empty()) { return per_file_metadata[0].get_num_columns(); }
    return 0;
  }

  /**
   * @brief Sums up the number of stripes of each source
   */
  size_type calc_num_stripes() const
  {
    return std::accumulate(
      per_file_metadata.begin(), per_file_metadata.end(), 0, [](auto &sum, auto &pfm) {
        return sum + pfm.get_num_stripes();
      });
  }

 public:
  aggregate_orc_metadata(std::vector<std::unique_ptr<datasource>> const &sources)
    : per_file_metadata(metadatas_from_sources(sources)),
      num_rows(calc_num_rows()),
      num_columns(calc_num_cols()),
      num_stripes(calc_num_stripes())
  {
    // Verify that the input files have matching numbers of columns
    int num_cols = -1;
    for (auto const &pfm : per_file_metadata) {
      if (num_cols == -1) { num_cols = pfm.get_num_columns(); }
      if (pfm.get_num_columns() != num_cols) {
        CUDF_EXPECTS(num_cols == static_cast<int>(pfm.get_num_columns()),
                     "All sources must have the same number of columns");
      }
    }

    // XXX: Need to talk with Vukasin about the best way to compare this schema ....
    // Comparing types is likely the best thing to do here.
    // // Verify that the input files have matching schemas
    // for (auto const &pfm : per_file_metadata) {
    //   CUDF_EXPECTS(per_file_metadata[0].schema == pfm.schema,
    //                "All sources must have the same schemas");
    // }
  }

  auto const &get_schema(int schema_idx) const { return per_file_metadata[0].ff.types[schema_idx]; }

  auto get_metadata_at_idx(int metadata_idx) const { return &per_file_metadata[metadata_idx]; };

  auto get_col_type(int col_idx) const { return per_file_metadata[0].ff.types[col_idx]; }

  auto get_num_rows() const { return num_rows; }

  auto get_num_cols() const { return num_columns; }

  auto get_num_stripes() const { return num_stripes; }

  auto get_num_source_files() const { return per_file_metadata.size(); }

  auto get_types() const { return per_file_metadata[0].ff.types; }

  int get_row_index_stride() const { return per_file_metadata[0].ff.rowIndexStride; }

  auto get_post_script_for_metadata(int metadata_idx) const
  {
    return per_file_metadata[metadata_idx].ps;
  }

  auto get_file_footer_for_metadata(int metadata_idx) const
  {
    return per_file_metadata[metadata_idx].ff;
  }

  auto get_column_name(const int source_idx, const int column_idx) const
  {
    return per_file_metadata[source_idx].get_column_name(column_idx);
  }

  std::vector<cudf::io::orc::metadata::stripe_source_mapping> select_stripes(
    std::vector<std::vector<size_type>> const &user_specified_stripes,
    size_type &row_start,
    size_type &row_count)
  {
    std::vector<cudf::io::orc::metadata::stripe_source_mapping> selected_stripes_mapping;

    if (!user_specified_stripes.empty()) {
      CUDF_EXPECTS(user_specified_stripes.size() == get_num_source_files(),
                   "Must specify stripes for each source");
      // row_start is 0 if stripes are set. If this is not true anymore, then
      // row_start needs to be subtracted to get the correct row_count
      CUDF_EXPECTS(row_start == 0, "Start row index should be 0");

      row_count = 0;
      // Each vector entry represents a source file; each nested vector represents the
      // user_defined_stripes to get from that source file
      for (size_t src_file_idx = 0; src_file_idx < user_specified_stripes.size(); ++src_file_idx) {
        std::vector<int> stripe_idxs;
        std::vector<OrcStripeInfo> stripe_infos;

        // Coalesce stripe info at the source file later since that makes downstream processing much
        // easier in impl::read
        for (const size_t &stripe_idx : user_specified_stripes[src_file_idx]) {
          CUDF_EXPECTS(
            stripe_idx >= 0 && stripe_idx < per_file_metadata[src_file_idx].ff.stripes.size(),
            "Invalid stripe index");
          stripe_idxs.push_back(stripe_idx);
          stripe_infos.push_back(
            std::make_pair(&per_file_metadata[src_file_idx].ff.stripes[stripe_idx], nullptr));
          row_count += per_file_metadata[src_file_idx].ff.stripes[stripe_idx].numberOfRows;
        }

        selected_stripes_mapping.push_back(
          {static_cast<int>(src_file_idx), stripe_idxs, stripe_infos});
      }
    } else {
      row_start = std::max(row_start, 0);
      if (row_count < 0) {
        row_count = static_cast<size_type>(
          std::min<int64_t>(get_num_rows(), std::numeric_limits<size_type>::max()));
      }
      row_count = std::min(row_count, get_num_rows() - row_start);
      CUDF_EXPECTS(row_count >= 0, "Invalid row count");
      CUDF_EXPECTS(row_start <= get_num_rows(), "Invalid row start");

      size_type count = 0;
      // Iterate all source files, each source file has corelating metadata
      for (size_t src_file_idx = 0; src_file_idx < per_file_metadata.size(); ++src_file_idx) {
        std::vector<int> stripe_idxs;
        std::vector<OrcStripeInfo> stripe_infos;

        for (size_t stripe_idx = 0; stripe_idx < per_file_metadata[src_file_idx].ff.stripes.size();
             ++stripe_idx) {
          count += per_file_metadata[src_file_idx].ff.numberOfRows;
          if (count > row_start || count == 0) {
            stripe_idxs.push_back(stripe_idx);
            stripe_infos.push_back(
              std::make_pair(&per_file_metadata[src_file_idx].ff.stripes[stripe_idx], nullptr));
          }
          if (count >= row_start + row_count) { break; }
        }

        selected_stripes_mapping.push_back(
          {static_cast<int>(src_file_idx), stripe_idxs, stripe_infos});
      }
    }

    // Read each stripe's stripefooter metadata
    if (not selected_stripes_mapping.empty()) {
      for (auto &mapping : selected_stripes_mapping) {
        // Resize to all stripe_info for the source level
        per_file_metadata[mapping.source_idx].stripefooters.resize(mapping.stripe_info.size());
        for (auto &stripe_idx : mapping.stripe_idx_in_source) {
          const auto stripe         = mapping.stripe_info[stripe_idx].first;
          const auto sf_comp_offset = stripe->offset + stripe->indexLength + stripe->dataLength;
          const auto sf_comp_length = stripe->footerLength;
          CUDF_EXPECTS(
            sf_comp_offset + sf_comp_length < per_file_metadata[mapping.source_idx].source->size(),
            "Invalid stripe information");
          const auto buffer =
            per_file_metadata[mapping.source_idx].source->host_read(sf_comp_offset, sf_comp_length);
          size_t sf_length = 0;
          auto sf_data     = per_file_metadata[mapping.source_idx].decompressor->Decompress(
            buffer->data(), sf_comp_length, &sf_length);
          ProtobufReader(sf_data, sf_length)
            .read(per_file_metadata[mapping.source_idx].stripefooters[stripe_idx]);
          mapping.stripe_info[stripe_idx].second =
            &per_file_metadata[mapping.source_idx].stripefooters[stripe_idx];
        }
      }
    }

    return selected_stripes_mapping;
  }

  uint32_t add_column(std::vector<std::vector<column_meta>> &selection,
                      std::vector<SchemaType> const &types,
                      size_t level,
                      uint32_t id,
                      uint32_t &num_lvl_child_columns,
                      bool &has_timestamp_column)
  {
    int num_cols_added = 1;
    if (level <= selection.size()) { selection.push_back(std::vector<column_meta>()); }
    selection[level].emplace_back(id, 0);
    int col_id = selection[level].size() - 1;
    if (types[id].kind == orc::TIMESTAMP) { has_timestamp_column = true; }
    uint32_t lvl_cols = 0;

    switch (types[id].kind) {
      case orc::LIST:
        if (not types[id].subtypes.empty()) {
          lvl_cols += 1;
          num_cols_added +=
            add_column(selection, types, level + 1, id + 1, lvl_cols, has_timestamp_column);
        }
        printf("RGSL : lvl %lu, col_id %d, lvl_cols %u\n", level, col_id, lvl_cols);
        selection[level][col_id].num_children = lvl_cols;
        break;

      case orc::STRUCT:
        for (auto child_id : types[id].subtypes) {
          num_lvl_child_columns += 1;
          num_cols_added += add_column(
            selection, types, level, child_id, num_lvl_child_columns, has_timestamp_column);
        }
        selection[level][col_id].num_children = num_lvl_child_columns;
        break;

      default: break;
    }

    return num_cols_added;
  }

  /**
   * @brief Filters and reduces down to a selection of columns
   *
   * @param use_names List of column names to select
   * @param has_timestamp_column True if timestamp column present and false otherwise
   *
   * @return input column information, output column information, list of output column schema
   * indices
   */
  std::vector<std::vector<column_meta>> select_columns(std::vector<std::string> use_names,
                                                       bool &has_timestamp_column)
  {
    auto const &pfm = per_file_metadata[0];
    std::vector<std::vector<column_meta>> selection;
    auto const num_columns = pfm.ff.types.size();
    uint32_t tmp           = 0;

    if (not use_names.empty()) {
      uint32_t index = 0;
      for (const auto &use_name : use_names) {
        bool name_found = false;
        for (uint32_t i = 0; i < num_columns; ++i, ++index) {
          if (index >= num_columns) { index = 0; }
          if (pfm.get_column_name(index) == use_name) {
            name_found = true;
            index += add_column(selection, pfm.ff.types, 0, index, tmp, has_timestamp_column);
            break;
          }
        }
        CUDF_EXPECTS(name_found, "Unknown column name : " + std::string(use_name));
      }
    } else {
      for (uint32_t i = 1; i < num_columns;) {
        i += add_column(selection, pfm.ff.types, 0, i, tmp, has_timestamp_column);
      }
    }

    return selection;
  }
};
rmm::device_buffer reader::impl::decompress_stripe_data(
  hostdevice_vector<gpu::ColumnDesc> &chunks,
  const std::vector<rmm::device_buffer> &stripe_data,
  const OrcDecompressor *decompressor,
  std::vector<orc_stream_info> &stream_info,
  size_t num_stripes,
  device_span<gpu::RowGroup> row_groups,
  size_t row_index_stride,
  rmm::cuda_stream_view stream)
{
  // Parse the columns' compressed info
  hostdevice_vector<gpu::CompressedStreamInfo> compinfo(0, stream_info.size(), stream);
  for (const auto &info : stream_info) {
    compinfo.insert(gpu::CompressedStreamInfo(
      static_cast<const uint8_t *>(stripe_data[info.stripe_idx].data()) + info.dst_pos,
      info.length));
  }
  compinfo.host_to_device(stream);
  gpu::ParseCompressedStripeData(compinfo.device_ptr(),
                                 compinfo.size(),
                                 decompressor->GetBlockSize(),
                                 decompressor->GetLog2MaxCompressionRatio(),
                                 stream);
  compinfo.device_to_host(stream, true);

  // Count the exact number of compressed blocks
  size_t num_compressed_blocks   = 0;
  size_t num_uncompressed_blocks = 0;
  size_t total_decomp_size       = 0;
  for (size_t i = 0; i < compinfo.size(); ++i) {
    num_compressed_blocks += compinfo[i].num_compressed_blocks;
    num_uncompressed_blocks += compinfo[i].num_uncompressed_blocks;
    total_decomp_size += compinfo[i].max_uncompressed_size;
  }
  CUDF_EXPECTS(total_decomp_size > 0, "No decompressible data found");

  rmm::device_buffer decomp_data(total_decomp_size, stream);
  rmm::device_uvector<gpu_inflate_input_s> inflate_in(
    num_compressed_blocks + num_uncompressed_blocks, stream);
  rmm::device_uvector<gpu_inflate_status_s> inflate_out(num_compressed_blocks, stream);

  // Parse again to populate the decompression input/output buffers
  size_t decomp_offset      = 0;
  uint32_t start_pos        = 0;
  uint32_t start_pos_uncomp = (uint32_t)num_compressed_blocks;
  for (size_t i = 0; i < compinfo.size(); ++i) {
    auto dst_base                 = static_cast<uint8_t *>(decomp_data.data());
    compinfo[i].uncompressed_data = dst_base + decomp_offset;
    compinfo[i].decctl            = inflate_in.data() + start_pos;
    compinfo[i].decstatus         = inflate_out.data() + start_pos;
    compinfo[i].copyctl           = inflate_in.data() + start_pos_uncomp;

    stream_info[i].dst_pos = decomp_offset;
    decomp_offset += compinfo[i].max_uncompressed_size;
    start_pos += compinfo[i].num_compressed_blocks;
    start_pos_uncomp += compinfo[i].num_uncompressed_blocks;
  }
  compinfo.host_to_device(stream);
  gpu::ParseCompressedStripeData(compinfo.device_ptr(),
                                 compinfo.size(),
                                 decompressor->GetBlockSize(),
                                 decompressor->GetLog2MaxCompressionRatio(),
                                 stream);

  // Dispatch batches of blocks to decompress
  if (num_compressed_blocks > 0) {
    switch (decompressor->GetKind()) {
      case orc::ZLIB:
        CUDA_TRY(
          gpuinflate(inflate_in.data(), inflate_out.data(), num_compressed_blocks, 0, stream));
        break;
      case orc::SNAPPY:
        CUDA_TRY(gpu_unsnap(inflate_in.data(), inflate_out.data(), num_compressed_blocks, stream));
        break;
      default: CUDF_EXPECTS(false, "Unexpected decompression dispatch"); break;
    }
  }
  if (num_uncompressed_blocks > 0) {
    CUDA_TRY(gpu_copy_uncompressed_blocks(
      inflate_in.data() + num_compressed_blocks, num_uncompressed_blocks, stream));
  }
  gpu::PostDecompressionReassemble(compinfo.device_ptr(), compinfo.size(), stream);

  // Update the stream information with the updated uncompressed info
  // TBD: We could update the value from the information we already
  // have in stream_info[], but using the gpu results also updates
  // max_uncompressed_size to the actual uncompressed size, or zero if
  // decompression failed.
  compinfo.device_to_host(stream, true);

  const size_t num_columns = chunks.size() / num_stripes;

  for (size_t i = 0; i < num_stripes; ++i) {
    for (size_t j = 0; j < num_columns; ++j) {
      auto &chunk = chunks[i * num_columns + j];
      for (int k = 0; k < gpu::CI_NUM_STREAMS; ++k) {
        if (chunk.strm_len[k] > 0 && chunk.strm_id[k] < compinfo.size()) {
          chunk.streams[k]  = compinfo[chunk.strm_id[k]].uncompressed_data;
          chunk.strm_len[k] = compinfo[chunk.strm_id[k]].max_uncompressed_size;
        }
      }
    }
  }

  if (not row_groups.empty()) {
    chunks.host_to_device(stream);
    gpu::ParseRowGroupIndex(row_groups.data(),
                            compinfo.device_ptr(),
                            chunks.device_ptr(),
                            num_columns,
                            num_stripes,
                            row_groups.size() / num_columns,
                            row_index_stride,
                            stream);
  }

  return decomp_data;
}

void reader::impl::decode_stream_data(hostdevice_vector<gpu::ColumnDesc> &chunks,
                                      size_t num_dicts,
                                      size_t skip_rows,
                                      size_t num_rows,
                                      timezone_table_view tz_table,
                                      device_span<gpu::RowGroup const> row_groups,
                                      size_t row_index_stride,
                                      std::vector<column_buffer> &out_buffers,
                                      rmm::cuda_stream_view stream)
{
  const auto num_columns = out_buffers.size();
  const auto num_stripes = chunks.size() / out_buffers.size();

  // Update chunks with pointers to column data
  for (size_t i = 0; i < num_stripes; ++i) {
    for (size_t j = 0; j < num_columns; ++j) {
      auto &chunk            = chunks[i * num_columns + j];
      chunk.column_data_base = out_buffers[j].data();
      chunk.valid_map_base   = out_buffers[j].null_mask();
    }
  }

  // Allocate global dictionary for deserializing
  rmm::device_uvector<gpu::DictionaryEntry> global_dict(num_dicts, stream);

  chunks.host_to_device(stream);
  gpu::DecodeNullsAndStringDictionaries(
    chunks.device_ptr(), global_dict.data(), num_columns, num_stripes, num_rows, skip_rows, stream);
  gpu::DecodeOrcColumnData(chunks.device_ptr(),
                           global_dict.data(),
                           num_columns,
                           num_stripes,
                           num_rows,
                           skip_rows,
                           tz_table,
                           row_groups.data(),
                           row_groups.size() / num_columns,
                           row_index_stride,
                           stream);
  chunks.device_to_host(stream, true);

  for (size_t i = 0; i < num_stripes; ++i) {
    for (size_t j = 0; j < num_columns; ++j) {
      out_buffers[j].null_count() += chunks[i * num_columns + j].null_count;
    }
  }
}

void reader::impl::aggregate_child_meta(hostdevice_vector<gpu::ColumnDesc> &chunks,
                                        std::vector<int32_t> &num_child_rows,
                                        std::vector<int32_t> &child_start_row,
                                        std::vector<int32_t> &num_child_rows_per_stripe,
                                        std::vector<column_meta> const &list_col,
                                        std::vector<int32_t> &orc_col_map,
                                        size_t number_of_stripes,
                                        int32_t level,
                                        rmm::cuda_stream_view stream)
{
  auto num_cols               = _selected_columns[level].size();
  auto num_child_cols         = _selected_columns[level + 1].size();
  auto number_of_child_chunks = num_child_cols * number_of_stripes;
  chunks.device_to_host(stream, true);
  printf("RGSL : number of child rows is %d \n", chunks[0].num_child_rows);
  num_child_rows.resize(_selected_columns[level + 1].size());
  child_start_row.resize(number_of_child_chunks);
  num_child_rows_per_stripe.resize(number_of_child_chunks);

  int index = 0;
  for (auto const p_col : list_col) {
    auto col_idx   = orc_col_map[p_col.id];
    auto start_row = 0;
    for (size_t i = 0; i < number_of_stripes; i++) {
      auto child_rows = chunks[i * num_cols + col_idx].num_child_rows;
      printf("RGSL: Child rows is %d p_col.num_children is %d\n", child_rows, p_col.num_children);
      for (uint32_t j = 0; j < p_col.num_children; j++) {
        num_child_rows_per_stripe[i * num_child_cols + index + j] = child_rows;
        child_start_row[i * num_child_cols + index + j]           = (i == 0) ? 0 : start_row;
        num_child_rows[j] += child_rows;
      }
      start_row += child_rows;
    }
    index += p_col.num_children;
  }
}

column_buffer &&reader::impl::assemble_buffer(int32_t orc_col_id,
                                              std::vector<std::vector<column_buffer>> &col_buffers,
                                              column_name_info &schema_info,
                                              std::vector<std::vector<int32_t>> const &orc_col_map,
                                              int level,
                                              rmm::cuda_stream_view stream,
                                              rmm::mr::device_memory_resource *mr)
{
  auto const col_id = orc_col_map[level][orc_col_id];
  auto &col_buffer  = col_buffers[level][col_id];
  schema_info.name  = _metadata->get_column_name(0, orc_col_id);
  switch (col_buffer.type.id()) {
    case type_id::LIST:
      schema_info.children.emplace_back("");
      col_buffer.children.emplace_back(
        assemble_buffer(_metadata->get_col_type(orc_col_id).subtypes[0],
                        col_buffers,
                        schema_info.children.back(),
                        orc_col_map,
                        level + 1,
                        stream,
                        mr));
      break;

    case type_id::STRUCT:
      for (auto col : _metadata->get_col_type(orc_col_id).subtypes) {
        schema_info.children.emplace_back("");
        col_buffer.children.emplace_back(assemble_buffer(
          col, col_buffers, schema_info.children.back(), orc_col_map, level, stream, mr));
      }

      break;

    default: break;
  }

  return std::move(col_buffer);
}

void reader::impl::create_columns(std::vector<std::vector<column_buffer>> &col_buffers,
                                  std::vector<std::unique_ptr<column>> &out_columns,
                                  std::vector<column_name_info> &schema_info,
                                  std::vector<std::vector<int>> const &orc_col_map,
                                  rmm::cuda_stream_view stream,
                                  rmm::mr::device_memory_resource *mr)
{
  for (size_t i = 0; i < _selected_columns[0].size();) {
    auto const &col_meta = _selected_columns[0][i];
    schema_info.emplace_back("");
    auto col_buffer =
      assemble_buffer(col_meta.id, col_buffers, schema_info.back(), orc_col_map, 0, stream, mr);
    out_columns.emplace_back(make_column(col_buffer, &schema_info.back(), stream, mr));
    i += (col_buffers[0][i].type.id() == type_id::STRUCT) ? col_meta.num_children : 1;
  }
}
reader::impl::impl(std::vector<std::unique_ptr<datasource>> &&sources,
                   orc_reader_options const &options,
                   rmm::mr::device_memory_resource *mr)
  : _mr(mr), _sources(std::move(sources))
{
  // Open and parse the source(s) dataset metadata
  _metadata = std::make_unique<aggregate_orc_metadata>(_sources);

  printf("RGSL : Selecting columns \n");
  // Select only columns required by the options
  _selected_columns = _metadata->select_columns(options.get_columns(), _has_timestamp_column);
  printf("RGSL : Selected columns \n");

  // Override output timestamp resolution if requested
  if (options.get_timestamp_type().id() != type_id::EMPTY) {
    _timestamp_type = options.get_timestamp_type();
  }

  // Enable or disable attempt to use row index for parsing
  _use_index = options.is_enabled_use_index();

  // Enable or disable the conversion to numpy-compatible dtypes
  _use_np_dtypes = options.is_enabled_use_np_dtypes();
}

table_with_metadata reader::impl::read(size_type skip_rows,
                                       size_type num_rows,
                                       const std::vector<std::vector<size_type>> &stripes,
                                       rmm::cuda_stream_view stream)
{
  std::vector<std::unique_ptr<column>> out_columns;
  std::vector<std::vector<int>> orc_col_id_map(_selected_columns.size());
  std::vector<std::vector<column_buffer>> out_buffers(_selected_columns.size());
  std::vector<std::vector<int32_t>> orc_col_map;
  table_metadata out_metadata;

  // TBD : Need to update num_rows for later set of levels

  // There are no columns in table
  if (_selected_columns.size() == 0) return {std::make_unique<table>(), std::move(out_metadata)};

  // Select only stripes required (aka row groups)
  const auto selected_stripes = _metadata->select_stripes(stripes, skip_rows, num_rows);

  std::vector<int32_t> num_child_rows;
  std::vector<int32_t> child_start_row;
  std::vector<int32_t> num_child_rows_per_stripe;
  for (size_t level = 0; level < _selected_columns.size(); level++) {
    printf("RGSL : Selecting column \n");
    auto &selected_columns = _selected_columns[level];
    printf("RGSL : After Selecting column \n");
    // Association between each ORC column and its cudf::column
    orc_col_map.emplace_back(_metadata->get_num_cols(), -1);
    std::vector<column_meta> list_col;

    // Get a list of column data types
    std::vector<data_type> column_types;
    for (auto &col : selected_columns) {
      auto col_type =
        to_type_id(_metadata->get_col_type(col.id), _use_np_dtypes, _timestamp_type.id());
      CUDF_EXPECTS(col_type != type_id::EMPTY, "Unknown type");
      // Remove this once we support Decimal128 data type
      CUDF_EXPECTS(
        (col_type != type_id::DECIMAL64) or (_metadata->get_types()[col.id].precision <= 18),
        "Decimal data has precision > 18, Decimal64 data type doesn't support it.");
      if (col_type == type_id::DECIMAL64) {
        // sign of the scale is changed since cuDF follows c++ libraries like CNL
        // which uses negative scaling, but liborc and other libraries
        // follow positive scaling.
        auto const scale = -static_cast<int32_t>(_metadata->get_types()[col.id].scale);
        column_types.emplace_back(col_type, scale);
      } else {
        column_types.emplace_back(col_type);
      }

      // Map each ORC column to its column
      orc_col_map[level][col.id] = column_types.size() - 1;
      if (col_type == type_id::LIST) list_col.emplace_back(col);
    }

    printf("RGSL : After forming column types \n");

    // If no rows or stripes to read, return empty columns
    if (num_rows <= 0 || selected_stripes.empty()) {
      std::transform(column_types.cbegin(),
                     column_types.cend(),
                     std::back_inserter(out_columns),
                     [](auto const &dtype) { return make_empty_column(dtype); });
    } else {
      const auto num_columns = selected_columns.size();
      const auto num_chunks  = selected_stripes.size() * num_columns;
      hostdevice_vector<gpu::ColumnDesc> chunks(num_chunks, stream);
      memset(chunks.host_ptr(), 0, chunks.memory_size());

      const bool use_index =
        (_use_index == true) &&
        // Only use if we don't have much work with complete columns & stripes
        // TODO: Consider nrows, gpu, and tune the threshold
        (num_rows > _metadata->get_row_index_stride() && !(_metadata->get_row_index_stride() & 7) &&
         _metadata->get_row_index_stride() > 0 &&
         num_columns * selected_stripes.size() < 8 * 128) &&
        // Only use if first row is aligned to a stripe boundary
        // TODO: Fix logic to handle unaligned rows
        (skip_rows == 0);

      // Logically view streams as columns
      std::vector<orc_stream_info> stream_info;

      // Tracker for eventually deallocating compressed and uncompressed data
      std::vector<rmm::device_buffer> stripe_data;

      size_t stripe_start_row = 0;
      size_t num_dict_entries = 0;
      size_t num_rowgroups    = 0;
      int stripe_idx          = 0;
      printf("RGSL : Before gathering stream \n");

      for (auto &stripe_source_mapping : selected_stripes) {
        // Iterate through the source files selected stripes
        for (auto &stripe : stripe_source_mapping.stripe_info) {
          const auto stripe_info   = stripe.first;
          const auto stripe_footer = stripe.second;

          auto stream_count          = stream_info.size();
          const auto total_data_size = gather_stream_info(stripe_idx,
                                                          stripe_info,
                                                          stripe_footer,
                                                          orc_col_map[level],
                                                          selected_columns,
                                                          _metadata->get_types(),
                                                          use_index,
                                                          &num_dict_entries,
                                                          chunks,
                                                          stream_info);

          CUDF_EXPECTS(total_data_size > 0, "Expected streams data within stripe");

          stripe_data.emplace_back(total_data_size, stream);
          auto dst_base = static_cast<uint8_t *>(stripe_data.back().data());

          // Coalesce consecutive streams into one read
          while (stream_count < stream_info.size()) {
            const auto d_dst  = dst_base + stream_info[stream_count].dst_pos;
            const auto offset = stream_info[stream_count].offset;
            auto len          = stream_info[stream_count].length;
            stream_count++;

            while (stream_count < stream_info.size() &&
                   stream_info[stream_count].offset == offset + len) {
              len += stream_info[stream_count].length;
              stream_count++;
            }
            if (_metadata->per_file_metadata[stripe_source_mapping.source_idx]
                  .source->is_device_read_preferred(len)) {
              CUDF_EXPECTS(
                _metadata->per_file_metadata[stripe_source_mapping.source_idx].source->device_read(
                  offset, len, d_dst, stream) == len,
                "Unexpected discrepancy in bytes read.");
            } else {
              const auto buffer =
                _metadata->per_file_metadata[stripe_source_mapping.source_idx].source->host_read(
                  offset, len);
              CUDF_EXPECTS(buffer->size() == len, "Unexpected discrepancy in bytes read.");
              CUDA_TRY(cudaMemcpyAsync(
                d_dst, buffer->data(), len, cudaMemcpyHostToDevice, stream.value()));
              stream.synchronize();
            }
          }

          printf("RGSL : After gathering streams num of columns %lu,  number of stripes %lu\n",
                 num_columns,
                 selected_stripes.size());
          // Update chunks to reference streams pointers
          uint32_t max_num_rows = 0;
          for (size_t col_idx = 0; col_idx < num_columns; col_idx++) {
            auto &chunk = chunks[stripe_idx * num_columns + col_idx];
            printf("RGSL : stripe idx %d num columns %lu colidx %lu \n",
                   stripe_idx,
                   num_columns,
                   col_idx);
            chunk.start_row =
              (level == 0) ? stripe_start_row : child_start_row[stripe_idx * num_columns + col_idx];
            printf("RGSL : After start row \n");
            chunk.num_rows = (level == 0)
                               ? stripe_info->numberOfRows
                               : num_child_rows_per_stripe[stripe_idx * num_columns + col_idx];
            printf("RGSL : chunk.column_stripe_num_rows %u \n", chunk.num_rows);
            printf("RGSL : After child row \n");
            chunk.column_num_rows = (level == 0) ? num_rows : num_child_rows[col_idx];
            printf("RGSL : chunk.column_num_rows %u \n", chunk.column_num_rows);
            printf("RGSL : After child rows row \n");
            chunk.encoding_kind = stripe_footer->columns[selected_columns[col_idx].id].kind;
            chunk.type_kind     = _metadata->per_file_metadata[stripe_source_mapping.source_idx]
                                .ff.types[selected_columns[col_idx].id]
                                .kind;
            chunk.decimal_scale = _metadata->per_file_metadata[stripe_source_mapping.source_idx]
                                    .ff.types[selected_columns[col_idx].id]
                                    .scale;
            chunk.rowgroup_id = num_rowgroups;
            chunk.dtype_len   = (column_types[col_idx].id() == type_id::STRING)
                                ? sizeof(std::pair<const char *, size_t>)
                                : (column_types[col_idx].id() == type_id::LIST)
                                    ? sizeof(int32_t)
                                    : cudf::size_of(column_types[col_idx]);
            if (chunk.type_kind == orc::TIMESTAMP) {
              chunk.ts_clock_rate = to_clockrate(_timestamp_type.id());
            }
            for (int k = 0; k < gpu::CI_NUM_STREAMS; k++) {
              chunk.streams[k] = dst_base + stream_info[chunk.strm_id[k]].dst_pos;
            }
            if (level > 0 and max_num_rows > chunk.num_rows) { max_num_rows = chunk.num_rows; }
          }
          auto num_rows_per_stripe = (level == 0) ? stripe_info->numberOfRows : max_num_rows;
          stripe_start_row += num_rows_per_stripe;
          if (use_index) {
            num_rowgroups += (num_rows_per_stripe + _metadata->get_row_index_stride() - 1) /
                             _metadata->get_row_index_stride();
          }

          stripe_idx++;
        }
      }

      // Process dataset chunk pages into output columns
      if (stripe_data.size() != 0) {
        // Setup row group descriptors if using indexes
        rmm::device_uvector<gpu::RowGroup> row_groups(num_rowgroups * num_columns, stream);
        CUDA_TRY(cudaMemsetAsync(
          row_groups.data(), 0, row_groups.size() * sizeof(gpu::RowGroup), stream.value()));
        printf("RGSL : stream_info size is %lu \n", stream_info.size());
        if (_metadata->per_file_metadata[0].ps.compression != orc::NONE) {
          auto decomp_data =
            decompress_stripe_data(chunks,
                                   stripe_data,
                                   _metadata->per_file_metadata[0].decompressor.get(),
                                   stream_info,
                                   selected_stripes.size(),
                                   row_groups,
                                   _metadata->get_row_index_stride(),
                                   stream);
          stripe_data.clear();
          stripe_data.push_back(std::move(decomp_data));
        } else {
          if (not row_groups.is_empty()) {
            chunks.host_to_device(stream);
            gpu::ParseRowGroupIndex(row_groups.data(),
                                    nullptr,
                                    chunks.device_ptr(),
                                    num_columns,
                                    selected_stripes.size(),
                                    num_rowgroups,
                                    _metadata->get_row_index_stride(),
                                    stream);
          }
        }

        printf("RGSL : After the Row group index formed %d \n", use_index);

        // Setup table for converting timestamp columns from local to UTC time
        auto const tz_table =
          _has_timestamp_column
            ? build_timezone_transition_table(
                selected_stripes[0].stripe_info[0].second->writerTimezone, stream)
            : timezone_table{};

        for (size_t i = 0; i < column_types.size(); ++i) {
          bool is_nullable = false;
          for (size_t j = 0; j < selected_stripes.size(); ++j) {
            if (chunks[j * num_columns + i].strm_len[gpu::CI_PRESENT] != 0) {
              is_nullable = true;
              break;
            }
          }
          auto is_list_type = (column_types[i].id() == type_id::LIST);
          auto n_rows       = (level == 0) ? num_rows : num_child_rows[i];
          n_rows += is_list_type;
          out_buffers[level].emplace_back(column_types[i], n_rows, is_nullable, stream, _mr);
        }

        printf("RGSL: Just before decoding \n");
        decode_stream_data(chunks,
                           num_dict_entries,
                           skip_rows,
                           num_rows,
                           tz_table.view(),
                           row_groups,
                           _metadata->get_row_index_stride(),
                           out_buffers[level],
                           stream);
        printf("RGSL: Just After decoding \n");

        // Extract information to process child columns
        if (list_col.size()) {
          aggregate_child_meta(chunks,
                               num_child_rows,
                               child_start_row,
                               num_child_rows_per_stripe,
                               list_col,
                               orc_col_map[level],
                               selected_stripes.size(),
                               level,
                               stream);
        }
        printf("RGSL: Just aggreagte buffer \n");
        printf(
          "RGSL : sizes of num_child_rows %lu, child_start_row %lu, num_child_rows_per_stripe %lu "
          "\n",
          num_child_rows.size(),
          child_start_row.size(),
          num_child_rows_per_stripe.size());
      }

      for (auto &out_buffer : out_buffers[level]) {
        printf("RGSL : Before update \n");
        if (out_buffer.type.id() == type_id::LIST) {
          auto data = static_cast<size_type *>(out_buffer.data());
          thrust::exclusive_scan(rmm::exec_policy(stream), data, data + out_buffer.size, data);
        }
        printf("RGSL : After update \n");
      }
      printf("RGSL : After for \n");
    }
  }

  std::vector<column_name_info> schema_info;
  create_columns(out_buffers, out_columns, schema_info, orc_col_map, stream, _mr);

  // Return column names (must match order of returned columns)
  out_metadata.column_names.resize(schema_info.size());
  for (size_t i = 0; i < schema_info.size(); i++) {
    out_metadata.column_names[i] = schema_info[i].name;
  }
  out_metadata.schema_info = std::move(schema_info);

  // XXX: Review question. Should metadata from all input files be included here as I am doing
  // or just a single input file? Return user metadata
  for (const auto &meta : _metadata->per_file_metadata) {
    for (const auto &kv : meta.ff.metadata) { out_metadata.user_data.insert({kv.name, kv.value}); }
  }

  return {std::make_unique<table>(std::move(out_columns)), std::move(out_metadata)};
}

// Forward to implementation
reader::reader(std::vector<std::string> const &filepaths,
               orc_reader_options const &options,
               rmm::cuda_stream_view stream,
               rmm::mr::device_memory_resource *mr)
{
  _impl = std::make_unique<impl>(datasource::create(filepaths), options, mr);
}

// Forward to implementation
reader::reader(std::vector<std::unique_ptr<cudf::io::datasource>> &&sources,
               orc_reader_options const &options,
               rmm::cuda_stream_view stream,
               rmm::mr::device_memory_resource *mr)
{
  _impl = std::make_unique<impl>(std::move(sources), options, mr);
}

// Destructor within this translation unit
reader::~reader() = default;

// Forward to implementation
table_with_metadata reader::read(orc_reader_options const &options, rmm::cuda_stream_view stream)
{
  return _impl->read(
    options.get_skip_rows(), options.get_num_rows(), options.get_stripes(), stream);
}
}  // namespace orc
}  // namespace detail
}  // namespace io
}  // namespace cudf
