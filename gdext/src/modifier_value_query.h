#pragma once

#include "modifier_api.h"
#include <algorithm>
#include <cmath>
#include <optional>
#include <unordered_map>

namespace pk::modifier_query {
using StatIds = std::unordered_map<std::string, int32_t>;

inline int32_t stat_id(const StatIds *ids, const std::string &key) {
    if (!ids) return -1;
    const auto it = ids->find(key);
    return it == ids->end() ? -1 : it->second;
}

template <typename Stats>
bool readable(const Stats &stats, int32_t domain, int32_t sid, double base_value) {
    return domain >= 0 && domain < ModifierApi::DOMAIN_COUNT &&
        sid >= 0 && static_cast<size_t>(sid) < stats.size() && stats[sid].domain == domain &&
        std::isfinite(base_value);
}

struct Terms { double add, factor; };

template <typename Stat, typename Lookup>
double effective(const Stat &stat, int32_t sid, uint64_t entity, uint64_t group, double base,
                 const DerivedCellFront *front, const Lookup &lookup) {
    double add = 0.0, factor = 1.0;
    const auto accumulate = [&](int32_t scope, uint64_t handle) {
        if (const auto terms = lookup(scope, handle)) {
            add += terms->add;
            factor *= terms->factor;
        }
    };
    accumulate(ModifierApi::GLOBAL, 0);
    // Group zero is an actual cell in Economy. Other domains use zero for no group.
    if (group != 0 || stat.domain == ModifierApi::ECONOMY) accumulate(ModifierApi::GROUP, group);
    accumulate(ModifierApi::ENTITY, entity);
    // Derived cell contributions join the normal sum and product before the
    // single final clamp. A zero factor annihilates the whole product.
    if (stat.domain == ModifierApi::ECONOMY && front && !front->rows.empty()) {
        const auto *row = front->row_for_stat(sid);
        const auto *cell = row ? row->find(static_cast<int32_t>(group)) : nullptr;
        if (cell) {
            add += cell->sum_add;
            if (cell->zero_factor_count > 0) factor = 0.0;
            else factor *= cell->product_nonzero;
        }
    }
    double value = (base + add) * factor;
    if (!std::isfinite(value)) value = value < 0.0 ? stat.min_value : stat.max_value;
    return std::clamp(value, stat.min_value, stat.max_value);
}
} // namespace pk::modifier_query
