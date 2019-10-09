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

#include <tests/utilities/legacy/cudf_test_fixtures.h>
#include <gtest/gtest.h>
#include <cudf/copying.hpp>
#include <cudf/table/table.hpp>
#include <utilities/cudf_utils.h>
#include <cudf/column/column_factories.hpp>
#include <tests/utilities/column_utilities.cuh>
#include <cudf/utilities/type_dispatcher.hpp>

void expect_columns_prop_equal(cudf::column_view lhs, cudf::column_view rhs) {
  EXPECT_EQ(lhs.type(), rhs.type());
  EXPECT_EQ(lhs.size(), rhs.size());
  EXPECT_EQ(lhs.null_count(), rhs.null_count());
  EXPECT_EQ(lhs.nullable(), rhs.nullable());
  EXPECT_EQ(lhs.has_nulls(), rhs.has_nulls());
  EXPECT_EQ(lhs.num_children(), rhs.num_children());
}

template <typename T>
struct EmptyLikeTest : GdfTest {};

using numeric_types =
    ::testing::Types<int8_t, int16_t, int32_t, int64_t, float, double>;

TYPED_TEST_CASE(EmptyLikeTest, numeric_types);

TYPED_TEST(EmptyLikeTest, NumericTests) {
    cudf::size_type size = 10;
    cudf::mask_state state = cudf::ALL_VALID;
    std::unique_ptr<cudf::column> input = make_numeric_column(cudf::data_type{cudf::exp::type_to_id<TypeParam>()}, size, state);
    std::unique_ptr<cudf::column> expected = make_numeric_column(cudf::data_type{cudf::exp::type_to_id<TypeParam>()}, 0);
    std::unique_ptr<cudf::column> got = cudf::exp::empty_like(input->view());
    expect_columns_prop_equal(*expected, *got);
}


