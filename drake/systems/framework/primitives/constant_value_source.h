#pragma once

#include <cstdint>
#include <memory>

#include "drake/systems/framework/context_base.h"
#include "drake/systems/framework/leaf_system.h"
#include "drake/systems/framework/system_output.h"
#include "drake/systems/framework/value.h"

namespace drake {
namespace systems {

/// A source block that always outputs a constant value.
/// @tparam T The vector element type, which must be a valid Eigen scalar.
template <typename T>
class ConstantValueSource : public LeafSystem<T> {
 public:
  /// @p value The constant value to emit.
  explicit ConstantValueSource(std::unique_ptr<AbstractValue> value);

  std::unique_ptr<SystemOutput<T>> AllocateOutput(
      const ContextBase<T>& context) const override;

  void EvalOutput(const ContextBase<T>& context,
                  SystemOutput<T>* output) const override;

 private:
  // TODO(david-german-tri): move source_value_ to the system's parameters.
  const std::unique_ptr<AbstractValue> source_value_;
};

}  // namespace systems
}  // namespace drake
