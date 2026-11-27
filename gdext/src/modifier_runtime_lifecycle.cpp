#include "modifier_runtime.h"
#include "modifier_value_query.h"

#include <algorithm>
#include <cmath>

namespace pk {

double ModifierRuntime::effective_value(int32_t domain, int32_t sid,
                                        uint64_t entity_handle,
                                        uint64_t group_handle,
                                        double base_value) const {
    return effective_value_with_front(domain, sid, entity_handle, group_handle,
                                      base_value, &_derived_cell_front);
}

double ModifierRuntime::effective_value_with_front(int32_t domain, int32_t sid,
        uint64_t entity_handle, uint64_t group_handle, double base_value,
        const DerivedCellFront *front) const {
    if (!_configured || !modifier_query::readable(_stats, domain, sid, base_value)) return base_value;
    const Store &store = _stores[domain];
    ++store.query_count;
    const auto lookup = [&](int32_t scope, uint64_t handle) -> std::optional<modifier_query::Terms> {
        const auto it = store.buckets.find({sid, scope, handle});
        if (it == store.buckets.end()) return {};
        ++store.bucket_reads;
        return modifier_query::Terms{it->second.sum_add, bucket_factor(it->second)};
    };
    return modifier_query::effective(_stats[sid], sid, entity_handle, group_handle, base_value, front, lookup);
}

double ModifierRuntime::effective_value(int32_t domain, const char *key,
                                        uint64_t entity_handle,
                                        uint64_t group_handle,
                                        double base_value) const {
    return effective_value(domain, stat_id(key), entity_handle, group_handle, base_value);
}

void ModifierRuntime::restore_derived_cell_layer(DerivedCellFront front) {
    _derived_layer_generation = front.generation;
    _derived_cell_front = std::move(front);
}

void ModifierRuntime::copy_derived_cell_layer_from(const ModifierRuntime &source) {
    const auto &front = source._derived_cell_front;
    if (_derived_cell_front.generation == front.generation &&
        _derived_cell_front.world_identity == front.world_identity &&
        _derived_cell_front.map_generation == front.map_generation) return;
    // Copy an empty front as well: removing the last contribution must reach
    // the consumer with the same generation as an ordinary replacement.
    _derived_cell_front = front;
    _derived_layer_generation = source._derived_layer_generation;
}

void ModifierRuntime::reset_runtime_state(int32_t cell_count) {
    _cell_count = cell_count;
    _current_day = -1;
    _pod_snapshot_generation = 0;
    _pending_commands.clear();
    _results.clear();
    _events.clear();
    _next_request_id = 1;
    _next_event_id = 1;
    _submit_order = 0;
    _journal_overflow = 0;
    _commands_applied = 0;
    _commands_rejected = 0;
    _expired = 0;
    _last_command_ms = 0.0;
    _last_expiry_ms = 0.0;
    _last_publish_ms = 0.0;
    _last_bucket_update_ms = 0.0;
    _last_bucket_rebuild_ms = 0.0;
    _bucket_update_ms_total = 0.0;
    _bucket_rebuild_ms_total = 0.0;
    _error_counts.clear();
    _derived_cell_front = DerivedCellFront{};
    _derived_layer_generation = 0;
    _derived_layer_installs = 0;
    _derived_layer_install_skips = 0;
    _derived_layer_int8_bytes = 0.0;
    for (int32_t domain = 0; domain < DOMAIN_COUNT; ++domain) clear_domain(domain);
    _gameplay_base_by_stat.assign(_stats.size(), {});
}

} // namespace pk
