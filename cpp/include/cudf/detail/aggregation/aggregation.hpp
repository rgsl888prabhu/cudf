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

#include <cudf/detail/utilities/device_operators.cuh>
#include <cudf/types.hpp>

namespace cudf {
namespace experimental {
/**
 * @brief Base class for specifying the desired aggregation in an
 * `aggregation_request`.
 *
 * This type is meant to be opaque in the public interface.
 *
 * Other kinds of aggregations may derive from this class to encapsulate
 * additional information needed to compute the aggregation.
 */
class aggregation {
 public:
  /**
   * @brief Possible aggregation operations
   */
  enum Kind {
    SUM,       ///< sum reduction
    MIN,       ///< min reduction
    MAX,       ///< max reduction
    COUNT,     ///< count number of elements
    MEAN,      ///< arithmetic mean reduction
    MEDIAN,    ///< median reduction
    QUANTILE,  ///< compute specified quantile(s)
    ARGMAX,    ///< Index of max element
    ARGMIN,     ///< Index of min element
    PTX,
    CUDA
  };

  aggregation(aggregation::Kind a) : kind{a} {}
  Kind kind;  ///< The aggregation to perform
};
namespace detail {
/**
 * @brief Derived class for specifying a quantile aggregation
 */
struct quantile_aggregation : aggregation {
  quantile_aggregation(std::vector<double> const& q,
                       experimental::interpolation i)
      : aggregation{QUANTILE}, _quantiles{q}, _interpolation{i} {}
  std::vector<double> _quantiles;              ///< Desired quantile(s)
  experimental::interpolation _interpolation;  ///< Desired interpolation
};

/**
 * @brief Derived class for specifying a udf aggregation
 */
struct udf_aggregation : aggregation {
  udf_aggregation(aggregation::Kind type,
          std::string const& user_defined_aggregator,
          data_type output_type): aggregation{type},
                                  source{user_defined_aggregator}, _output_type{output_type} {}
  std::string const source;
  data_type _output_type;
};

/**
 * @brief Sentinel value used for `ARGMAX` aggregation.
 *
 * The output column for an `ARGMAX` aggregation is initialized with the
 * sentinel value to indicate an unused element.
 */
constexpr size_type ARGMAX_SENTINEL{-1};

/**
 * @brief Sentinel value used for `ARGMIN` aggregation.
 *
 * The output column for an `ARGMIN` aggregation is initialized with the
 * sentinel value to indicate an unused element.
 */
constexpr size_type ARGMIN_SENTINEL{-1};

/**	
 * @brief Maps an `aggregation::Kind` value to it's corresponding binary	
 * operator.	
 *	
 * @note Not all values of `aggregation::Kind` have a valid corresponding binary	
 * operator. For these values `E`,	
 * `std::is_same_v<corresponding_operator<E>::type, void>`.	
 *	
 * @tparam k The `aggregation::Kind` value to map to its corresponding operator	
 */	
template <aggregation::Kind k>	
struct corresponding_operator {	
    using type = void;	
};	

template <>	
struct corresponding_operator<aggregation::MIN> {	
  using type = DeviceMin;	
};	
template <>	
struct corresponding_operator<aggregation::MAX> {	
  using type = DeviceMax;	
};	
template <>	
struct corresponding_operator<aggregation::SUM> {	
  using type = DeviceSum;	
};	

template <aggregation::Kind k>	
using corresponding_operator_t = typename corresponding_operator<k>::type;	

/**---------------------------------------------------------------------------*
 * @brief Determines accumulator type based on input type and aggregation.
 *
 * @tparam Source The type on which the aggregation is computed
 * @tparam k The aggregation performed
 *---------------------------------------------------------------------------**/
template <typename Source, aggregation::Kind k, typename Enable = void>
struct target_type_impl {
  using type = void;
};

// Computing MIN of Source, use Source accumulator
template <typename Source>
struct target_type_impl<Source, aggregation::MIN> {
  using type = Source;
};

// Computing MAX of Source, use Source accumulator
template <typename Source>
struct target_type_impl<Source, aggregation::MAX> {
  using type = Source;
};

// Always use size_type accumulator for COUNT
template <typename Source>
struct target_type_impl<Source, aggregation::COUNT> {
  using type = cudf::size_type;
};

// Always use `double` for MEAN
template <typename Source>
struct target_type_impl<Source, aggregation::MEAN> {
  using type = double;
};

// Summing integers of any type, always use int64_t accumulator
template <typename Source>
struct target_type_impl<Source, aggregation::SUM,
                        std::enable_if_t<std::is_integral<Source>::value>> {
  using type = int64_t;
};

// Summing float/doubles, use same type accumulator
template <typename Source>
struct target_type_impl<
    Source, aggregation::SUM,
    std::enable_if_t<std::is_floating_point<Source>::value>> {
  using type = Source;
};

// Summing timestamps, use same type accumulator
template <typename Source>
struct target_type_impl<Source, aggregation::SUM,
                        std::enable_if_t<is_timestamp<Source>()>> {
  using type = Source;
};

// Always use `double` for quantile
template <typename Source>
struct target_type_impl<Source, aggregation::QUANTILE> {
  using type = double;
};

// MEDIAN is a special case of a QUANTILE
template <typename Source>
struct target_type_impl<Source, aggregation::MEDIAN> {
  using type = target_type_impl<Source, aggregation::QUANTILE>;
};

// Always use `size_type` for ARGMAX index
template <typename Source>
struct target_type_impl<Source, aggregation::ARGMAX> {
  using type = size_type;
};

// Always use `size_type` for ARGMIN index
template <typename Source>
struct target_type_impl<Source, aggregation::ARGMIN> {
  using type = size_type;
};

/**
 * @brief Helper alias to get the accumulator type for performing aggregation
 * `k` on elements of type `Source`
 *
 * @tparam Source The type on which the aggregation is computed
 * @tparam k The aggregation performed
 */
template <typename Source, aggregation::Kind k>
using target_type_t = typename target_type_impl<Source, k>::type;

/**
 * @brief Dispatches `k` as a non-type template parameter to a callable,  `f`.
 *
 * @tparam F Type of callable
 * @param k The `aggregation::Kind` value to dispatch
 * aram f The callable that accepts an `aggregation::Kind` non-type template
 * argument.
 * @param args Parameter pack forwarded to the `operator()` invocation
 * @return Forwards the return value of the callable.
 */
#pragma nv_exec_check_disable
template <typename F, typename... Ts>
CUDA_HOST_DEVICE_CALLABLE decltype(auto) aggregation_dispatcher(
    aggregation::Kind k, F&& f, Ts&&... args) {
  switch (k) {
    case aggregation::SUM:
      return f.template operator()<aggregation::SUM>(std::forward<Ts>(args)...);
    case aggregation::MIN:
      return f.template operator()<aggregation::MIN>(std::forward<Ts>(args)...);
    case aggregation::MAX:
      return f.template operator()<aggregation::MAX>(std::forward<Ts>(args)...);
    case aggregation::COUNT:
      return f.template operator()<aggregation::COUNT>(
          std::forward<Ts>(args)...);
    case aggregation::MEAN:
      return f.template operator()<aggregation::MEAN>(
          std::forward<Ts>(args)...);
    case aggregation::MEDIAN:
      return f.template operator()<aggregation::MEDIAN>(
          std::forward<Ts>(args)...);
    case aggregation::QUANTILE:
      return f.template operator()<aggregation::QUANTILE>(
          std::forward<Ts>(args)...);
    case aggregation::ARGMAX:
      return f.template operator()<aggregation::ARGMAX>(
          std::forward<Ts>(args)...);
    case aggregation::ARGMIN:
      return f.template operator()<aggregation::ARGMIN>(
          std::forward<Ts>(args)...);
    default: {
#ifndef __CUDA_ARCH__
      CUDF_FAIL("Unsupported aggregation.");
#else
      release_assert(false && "Unsuported aggregation.");

      // The following code will never be reached, but the compiler generates a
      // warning if there isn't a return value.

      // Need to find out what the return type is in order to have a default
      // return value and solve the compiler warning for lack of a default
      // return
      using return_type =
          decltype(f.template operator()<aggregation::SUM>(
            std::forward<Ts>(args)...));
      return return_type();
#endif
    }
  }
}

template <typename Element>
struct dispatch_aggregation {
#pragma nv_exec_check_disable
  template <aggregation::Kind k, typename F, typename... Ts>
  CUDA_HOST_DEVICE_CALLABLE decltype(auto) operator()(F&& f, Ts&&... args) const
      noexcept {
    return f.template operator()<Element, k>(std::forward<Ts>(args)...);
  }
};

struct dispatch_source {
#pragma nv_exec_check_disable
  template <typename Element, typename F, typename... Ts>
  CUDA_HOST_DEVICE_CALLABLE decltype(auto) operator()(aggregation::Kind k,
                                                      F&& f, Ts&&... args) const
      noexcept {
    return aggregation_dispatcher(k, dispatch_aggregation<Element>{},
                                  std::forward<F>(f),
                                  std::forward<Ts>(args)...);
  }
};

/**
 * @brief Dispatches both a type and `aggregation::Kind` template parameters to
 * a callable.
 *
 * This function expects a callable `f` with an `operator()` template accepting
 * two template parameters. The first is a type dispatched from `type`. The
 * second is an `aggregation::Kind` dispatched from `k`.
 *
 * @param type The `data_type` used to dispatch a type for the first template
 * parameter of the callable `F`
 * @param k The `aggregation::Kind` used to dispatch an `aggregation::Kind`
 * non-type template parameter for the second template parameter of the callable
 * @param args Parameter pack forwarded to the `operator()` invocation
 * `F`.
 */
#pragma nv_exec_check_disable
template <typename F, typename... Ts>
CUDA_HOST_DEVICE_CALLABLE constexpr decltype(auto)
dispatch_type_and_aggregation(data_type type, aggregation::Kind k, F&& f,
                              Ts&&... args) {
  return type_dispatcher(type, dispatch_source{}, k, std::forward<F>(f),
                         std::forward<Ts>(args)...);
}
/**
 * @brief Returns the target `data_type` for the specified aggregation  k
 * performed on elements of type  source_type.
 *
 * aram source_type The element type to be aggregated
 * aram k The aggregation
 * @return data_type The target_type of  k performed on  source_type
 * elements
 */
data_type target_type(data_type source_type, aggregation::Kind k);

/**
 * @brief Indicates whether the specified aggregation `k` is valid to perform on
 * the type `Source`.
 *
 * @tparam Source Type on which the aggregation is performed
 * @tparam k The aggregation to perform
 */
template <typename Source, aggregation::Kind k>
constexpr inline bool is_valid_aggregation() {
  return (not std::is_void<target_type_t<Source, k>>::value);
}

/**
 * @brief Indicates whether the specified aggregation `k` is valid to perform on
 * the `data_type` `source`.
 *
 * @param source Source `data_type` on which the aggregation is performed
 * @param k The aggregation to perform
 */
bool is_valid_aggregation(data_type source, aggregation::Kind k);

}  // namespace detail
}  // namespace experimental
}  // namespace cudf
