/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
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

#pragma once

#include <cudf/types.hpp>

#include <memory>
#include <vector>

/**
 * @file aggregation.hpp
 * @brief Representation for specifying desired aggregations from
 * aggregation-based APIs, e.g., groupby, reductions, rolling, etc.
 *
 * @note Not all aggregation APIs support all aggregation operations. See
 * individual function documentation to see what aggregations are supported.
 *
 */

namespace cudf {
namespace experimental {
/**
 * @brief Base class for abstract representation of an aggregation.
 */
class aggregation;

/// Factory to create a SUM aggregation
std::unique_ptr<aggregation> make_sum_aggregation();

/// Factory to create a MIN aggregation
std::unique_ptr<aggregation> make_min_aggregation();

/// Factory to create a MAX aggregation
std::unique_ptr<aggregation> make_max_aggregation();

/// Factory to create a COUNT aggregation
std::unique_ptr<aggregation> make_count_aggregation();

/// Factory to create a MEAN aggregation
std::unique_ptr<aggregation> make_mean_aggregation();

/// Factory to create a MEDIAN aggregation
std::unique_ptr<aggregation> make_median_aggregation();

/**
 * @brief Factory to create a QUANTILE aggregation
 *
 * @param quantiles The desired quantiles
 * @param interpolation The desired interpolation
 */
std::unique_ptr<aggregation> make_quantile_aggregation(
    std::vector<double> const& q, interpolation i);

/**
 * @brief Factory to create an `argmax` aggregation
 * 
 * `argmax` returns the index of the maximum element.
*/
std::unique_ptr<aggregation> make_argmax_aggregation();


/**
 * @brief Factory to create an `argmin` aggregation
 * 
 * `argmin` returns the index of the minimum element.
*/
std::unique_ptr<aggregation> make_argmin_aggregation();


/**
 * @brief Factory to create a PTX aggregation
 *
 * @param[in] user_defined_aggregator A string which has the required aggregation
 * @param[in] output_type expected output type
 *
 * @return aggregation unique pointer housing user_defined_aggregator PTX string.
 */
std::unique_ptr<aggregation> make_ptx_aggregation(std::string user_defined_aggregator, data_type output_type);

/**
 * @brief Factory to create a CUDA aggregation
 *
 * @param[in] user_defined_aggregator A string which has the required aggregation
 * @param[in] output_type expected output type
 *
 * @return aggregation unique pointer housing user_defined_aggregator CUDA string.
 */
std::unique_ptr<aggregation> make_cuda_aggregation(std::string user_defined_aggregator, data_type output_type);


}  // namespace experimental
}  // namespace cudf
