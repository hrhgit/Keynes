#include "native_simulation_host.h"
#include "runtime_checkpoint_wire.h"

#include <algorithm>

namespace pk {
namespace {
constexpr uint32_t EFFECT_TRANSPORT_LEGACY = 0x31515445u; // ETQ1
constexpr uint32_t EFFECT_TRANSPORT_MARKER = 0x32515445u; // ETQ2

template <typename Fields>
auto dated(Fields fields, bool has_day) {
    return [fields, has_day](auto &io, auto &entry) {
        return (!has_day || (io.field(entry.admitted_day) && entry.admitted_day >= 0)) &&
            fields(io, entry);
    };
}

constexpr auto instance_fields = [](auto &io, auto &entry) {
    auto &value = entry.input;
    return io.field(entry.sequence) && io.field(value.instance_id) &&
        io.field(value.generation) && io.field(value.program_id) &&
        io.field(value.source_type) && io.field(value.source_id) &&
        io.field(value.source_handle) && io.field(value.target_handle) &&
        io.field(value.target_generation) && io.field(value.level) &&
        io.field(value.next_due_day) && io.field(value.expires_day) &&
        io.field(value.magnitude_scale_q16) && io.field(value.latched) &&
        io.field(value.active);
};

constexpr auto metric_fields = [](auto &io, auto &entry) {
    return io.field(entry.instance_id) && io.field(entry.generation) &&
        io.field(entry.metric_id) && io.field(entry.revision) && io.field(entry.value);
};

constexpr auto removal_fields = [](auto &io, auto &entry) {
    return io.field(entry.sequence) && io.field(entry.instance_id) && io.field(entry.generation);
};

constexpr auto ack_fields = [](auto &io, auto &entry) {
    return io.field(entry.request_id) && io.field(entry.transaction_id) &&
        io.field(entry.target_handle) && io.field(entry.target_generation) &&
        io.field(entry.domain) && io.field(entry.code) &&
        io.field(entry.effective_day) && io.field(entry.producer_id) &&
        io.field(entry.sequence) && io.field(entry.technology_flags);
};
} // namespace

std::vector<uint8_t> NativeSimulationHost::encode_effect_transport() const {
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    CheckpointWriter out;
    out.field(EFFECT_TRANSPORT_MARKER);
    out.field(_effect_transport_sequence);
    // Only changes to one identity have a causal order. Persist those chains
    // by identity with canonical ordinals, independently of producer interleaving.
    auto instances = _effect_instance_queue;
    auto removals = _effect_remove_queue;
    sort_effect_inputs(instances, removals);
    auto bind = instances.begin();
    auto retire = removals.begin();
    uint64_t ordinal = 0;
    while (bind != instances.end() || retire != removals.end()) {
        if (retire == removals.end() || (bind != instances.end() && bind->order_key() < retire->order_key()))
            (bind++)->sequence = ++ordinal;
        else
            (retire++)->sequence = ++ordinal;
    }
    auto metrics = _effect_metric_queue;
    std::sort(metrics.begin(), metrics.end());
    auto acks = _effect_acks;
    sort_effect_receipts(acks);
    out.rows(instances, dated(instance_fields, true));
    out.rows(metrics, dated(metric_fields, true));
    out.rows(removals, dated(removal_fields, true));
    out.rows(acks, ack_fields);
    return std::move(out.bytes);
}

bool NativeSimulationHost::validate_effect_transport_metrics(
        std::deque<EffectPodMetricQueueItem> &metrics, const std::deque<EffectPodInstanceQueueItem> &instances,
        const RuntimeSaveBundle &bundle, const RuntimeEffectPodAuthority &saved_effect) const {
    std::vector<EffectPodMetricQueueItem *> legacy;
    for (auto &metric : metrics) {
        if (_effect_pod_catalog.valid_metric_input(metric.metric_id, metric.revision)) continue;
        if (bundle.bundle_version != RUNTIME_SAVE_BUNDLE_LEGACY_V5 ||
            !_effect_pod_catalog.valid_metric_input(metric.metric_id, 0)) return false;
        legacy.push_back(&metric);
    }
    if (legacy.empty()) return true;

    // Old writers accepted negative revisions. set_metric checked identity first:
    // match the saved generation after bindings eligible on the observation's day.
    // Retirements keep their identity (even an inactive tombstone accepts metrics).
    const auto open_day = [&](int64_t admitted) { return std::max(bundle.committed_day + 1, admitted); };
    std::vector<const EffectPodInstanceQueueItem *> bindings;
    for (const auto &bind : instances) bindings.push_back(&bind);
    const auto key = [&](const auto *bind) { return std::make_pair(open_day(bind->admitted_day), bind->sequence); };
    std::sort(bindings.begin(), bindings.end(), [&](auto *a, auto *b) { return key(a) < key(b); });
    std::sort(legacy.begin(), legacy.end(), [](auto *a, auto *b) { return a->admitted_day < b->admitted_day; });
    std::unordered_map<int64_t, uint32_t> generations;
    for (const auto &row : saved_effect.snapshot().instances) generations[row.instance_id] = row.generation;
    auto next = bindings.begin();
    for (auto *metric : legacy) {
        while (next != bindings.end() && open_day((*next)->admitted_day) <= open_day(metric->admitted_day)) {
            const auto &bind = **next++;
            auto input = bind.input;
            input.next_due_day = std::max(input.next_due_day, open_day(bind.admitted_day));
            std::string error;
            if (saved_effect.validate_instance(input, error)) generations[input.instance_id] = input.generation;
        }
        const auto live = generations.find(metric->instance_id);
        if (live != generations.end() && live->second == metric->generation) return false;
        // Preserve the dated discard, including across an immediate v6 resave.
        // Generation zero never binds, even if this identity is registered again.
        metric->generation = 0;
        metric->revision = 0;
    }
    return true;
}

bool NativeSimulationHost::restore_effect_transport(
        const RuntimeSaveBundle &bundle, const RuntimeEffectPodAuthority &saved_effect, bool install) {
    const auto &bytes = bundle.effect_transport_bytes;
    CheckpointReader in{bytes.data(), bytes.size()};
    uint32_t marker = 0;
    uint64_t sequence = 0;
    decltype(_effect_instance_queue) instances;
    decltype(_effect_metric_queue) metrics;
    decltype(_effect_remove_queue) removals;
    decltype(_effect_acks) acks;
    const bool has_marker = in.field(marker);
    const bool has_day = marker == EFFECT_TRANSPORT_MARKER;
    const bool v5 = bundle.bundle_version == RUNTIME_SAVE_BUNDLE_LEGACY_V5;
    const bool declared = (bundle.section_mask & RUNTIME_SAVE_SECTION_EFFECT_TRANSPORT) != 0;
    if (declared) {
        if (!has_marker || (!has_day && !(v5 && marker == EFFECT_TRANSPORT_LEGACY)) ||
            !in.field(sequence) || !in.rows(instances, dated(instance_fields, has_day)) ||
            !in.rows(metrics, dated(metric_fields, has_day)) ||
            !in.rows(removals, dated(removal_fields, has_day)) ||
            !in.rows(acks, ack_fields) || in.cursor != in.size) return false;
    } else if (!v5 || !bytes.empty()) {
        return false;
    }
    // Both historical queues use strictly increasing, shared ordinals.
    auto binding = instances.begin();
    auto removal = removals.begin();
    uint64_t previous = 0;
    while (binding != instances.end() || removal != removals.end()) {
        const bool take_binding = removal == removals.end() ||
            (binding != instances.end() && binding->sequence < removal->sequence);
        const uint64_t current = take_binding ? (binding++)->sequence : (removal++)->sequence;
        if (current <= previous || current > sequence) return false;
        previous = current;
    }
    if (!validate_effect_transport_metrics(metrics, instances, bundle, saved_effect)) return false;
    if (!install) return true;
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    _effect_transport_sequence = sequence;
    _effect_instance_queue = std::move(instances);
    _effect_metric_queue = std::move(metrics);
    _effect_remove_queue = std::move(removals);
    rebuild_effect_queue_index_locked();
    _effect_acks = std::move(acks);
    _effect_ready_ack_count = 0; // A saved whole day opens its next receipt batch at the next seal.
    _effect_intents.clear();
    return true;
}
} // namespace pk
