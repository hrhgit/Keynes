#pragma once

#include <cstdint>

namespace pk {

// Worker-issued catalog IDs stop at the start of the built-in namespace.
constexpr int64_t EFFECT_BUILTIN_TRANSACTION_ID_BASE = int64_t{1} << 50;

} // namespace pk
