#include "native_simulation_host.h"
#include "runtime_checkpoint_wire.h"

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
    out.rows(_effect_instance_queue, dated(instance_fields, true));
    out.rows(_effect_metric_queue, dated(metric_fields, true));
    out.rows(_effect_remove_queue, dated(removal_fields, true));
    out.rows(_effect_acks, ack_fields);
    return std::move(out.bytes);
}

bool NativeSimulationHost::restore_effect_transport(const std::vector<uint8_t> &bytes, bool install) {
    CheckpointReader in{bytes.data(), bytes.size()};
    uint32_t marker = 0;
    uint64_t sequence = 0;
    decltype(_effect_instance_queue) instances;
    decltype(_effect_metric_queue) metrics;
    decltype(_effect_remove_queue) removals;
    decltype(_effect_acks) acks;
    const bool has_marker = in.field(marker);
    const bool has_day = marker == EFFECT_TRANSPORT_MARKER;
    if (!bytes.empty() && (!has_marker || (!has_day && marker != EFFECT_TRANSPORT_LEGACY) ||
            !in.field(sequence) || !in.rows(instances, dated(instance_fields, has_day)) ||
            !in.rows(metrics, dated(metric_fields, has_day)) ||
            !in.rows(removals, dated(removal_fields, has_day)) ||
            !in.rows(acks, ack_fields) || in.cursor != in.size)) return false;
    if (!install) return true;
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    _effect_transport_sequence = sequence;
    _effect_instance_queue = std::move(instances);
    _effect_metric_queue = std::move(metrics);
    _effect_remove_queue = std::move(removals);
    _effect_acks = std::move(acks);
    _effect_intents.clear();
    return true;
}
} // namespace pk
