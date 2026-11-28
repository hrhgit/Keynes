#include "native_simulation_host.h"

#include <algorithm>
#include <limits>
#include <tuple>
#include <unordered_set>

namespace pk {
namespace {
auto binding_fields(const RuntimeEffectPodInstanceInput &in) {
    return std::tie(in.instance_id, in.generation, in.program_id, in.source_type, in.source_id,
        in.source_handle, in.target_handle, in.target_generation, in.level,
        in.magnitude_scale_q16, in.latched, in.active);
}
} // namespace

bool NativeSimulationHost::EffectPodMetricQueueItem::operator<(const EffectPodMetricQueueItem &other) const {
    const auto key = [](const auto &row) {
        return std::tie(row.admitted_day, row.instance_id, row.generation,
                       row.metric_id, row.revision, row.value);
    };
    return key(*this) < key(other);
}

void NativeSimulationHost::sort_effect_inputs(std::deque<EffectPodInstanceQueueItem> &instances,
                                             std::deque<EffectPodRemoveQueueItem> &removals) {
    const auto by_identity = [](const auto &a, const auto &b) { return a.order_key() < b.order_key(); };
    std::sort(instances.begin(), instances.end(), by_identity);
    std::sort(removals.begin(), removals.end(), by_identity);
}

void NativeSimulationHost::sort_effect_receipts(std::deque<RuntimeDomainAck> &receipts) {
    std::stable_sort(receipts.begin(), receipts.end(), [](const auto &a, const auto &b) {
        return a.transaction_id < b.transaction_id;
    });
}

void NativeSimulationHost::include_effect_day_peer_receipts_locked(int64_t day) {
    const auto &snapshot = _effect_pod_authority.snapshot();
    if (snapshot.committed_day != day || _effect_ready_ack_count == _effect_acks.size()) return;
    // A continuation can finish today's own transactions and the exact older
    // transaction on which a sealed Country request is currently parked.
    std::unordered_set<uint64_t> current_transactions;
    for (const auto &tx : snapshot.transactions) {
        if (tx.effective_day == day) current_transactions.insert(static_cast<uint64_t>(tx.transaction_id));
    }
    for (const auto &[request, result] : _country_worker_results) {
        const auto *wait = pending_country_effect_peer_locked(request, result);
        if (!wait || wait->day != day) continue;
        const auto view = _effect_pod_authority.copy_committed_view(wait->effect_instance_id);
        if (view.found && view.instance.generation == wait->effect_generation &&
                view.instance.pending_transaction_id > 0)
            current_transactions.insert(static_cast<uint64_t>(view.instance.pending_transaction_id));
    }
    auto first = _effect_acks.begin() + static_cast<ptrdiff_t>(_effect_ready_ack_count);
    const auto end = std::stable_partition(first, _effect_acks.end(), [&](const auto &ack) {
        return current_transactions.count(ack.transaction_id) != 0;
    });
    _effect_ready_ack_count = static_cast<size_t>(end - _effect_acks.begin());
}

bool NativeSimulationHost::allocate_effect_input_sequence_locked(uint64_t &sequence, std::string &error) {
    if (_effect_transport_sequence == std::numeric_limits<uint64_t>::max()) {
        error = "effect_transport_sequence_exhausted";
        return false;
    }
    sequence = ++_effect_transport_sequence;
    return true;
}

// Erasing ready requests moves deque entries. Reconstruct the index under the
// transport lock after an erase, a rollback, or the installation of a checkpoint.
void NativeSimulationHost::rebuild_effect_queue_index_locked() {
    _last_queued_effect_instance.clear();
    for (auto &item : _effect_instance_queue) {
        auto &last = _last_queued_effect_instance[item.input.instance_id];
        if (!last || last->sequence < item.sequence) last = &item;
    }
    for (const auto &remove : _effect_remove_queue) {
        const auto it = _last_queued_effect_instance.find(remove.instance_id);
        if (it != _last_queued_effect_instance.end() && it->second->sequence < remove.sequence)
            _last_queued_effect_instance.erase(it);
    }
}

RuntimeCommandAdmission NativeSimulationHost::admit_effect_input(int64_t &admitted_day) {
    // Bootstrap has no open day. Executor-produced effects are consequences
    // of the current sealed inputs and are already ordered by the day plan.
    const bool settling_day = on_worker_thread() && _worker_day_inflight.load(std::memory_order_acquire) != 0;
    if (settling_day || _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::OFF)
        return RuntimeCommandAdmission(true);
    RuntimeCommandAdmission admission(_command_producer_mutex, _command_seal);
    // The CAS in try_freeze_command_inputs linearizes admission. Its generic
    // fence can reopen for inline peer commands, while the Effect seal persists.
    admitted_day = std::max({committed_day_value(), frozen_command_day(),
        _effect_input_sealed_day.load(std::memory_order_acquire)}) + 1;
    return admission;
}

bool NativeSimulationHost::queue_effect_pod_instance(
        const RuntimeEffectPodInstanceInput &input, std::string &error, bool day_consequence) {
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    int64_t admitted_day = 0;
    auto admission = day_consequence ? RuntimeCommandAdmission(true) : admit_effect_input(admitted_day);
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    return append_effect_instance_locked(input, admitted_day, error);
}

std::vector<uint8_t> NativeSimulationHost::queue_effect_pod_instances(
        const std::vector<RuntimeEffectPodInstanceInput> &inputs, std::string &error) {
    std::vector<uint8_t> accepted(inputs.size(), 0);
    if (inputs.empty()) return accepted;
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return accepted;
    }
    int64_t admitted_day = 0;
    auto admission = admit_effect_input(admitted_day);
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    for (size_t i = 0; i < inputs.size(); ++i)
        accepted[i] = append_effect_instance_locked(inputs[i], admitted_day, error);
    return accepted;
}

bool NativeSimulationHost::append_effect_instance_locked(
        const RuntimeEffectPodInstanceInput &input, int64_t admitted_day, std::string &error) {
    // Rescheduling the same pending binding uses its existing slot. Changes to
    // lifecycle inputs still pass through upsert_instance in their causal order.
    const auto previous = _last_queued_effect_instance.find(input.instance_id);
    if (previous != _last_queued_effect_instance.end() &&
        previous->second->admitted_day == admitted_day &&
        binding_fields(previous->second->input) == binding_fields(input)) {
        previous->second->input.next_due_day = input.next_due_day;
        previous->second->input.expires_day = input.expires_day;
        return true;
    }
    if (_effect_instance_queue.size() >= RUNTIME_COMMAND_QUEUE_CAPACITY) {
        error = "effect_instance_capacity_exceeded";
        return false;
    }
    EffectPodInstanceQueueItem item;
    item.admitted_day = admitted_day;
    if (!allocate_effect_input_sequence_locked(item.sequence, error)) return false;
    item.input = input;
    _effect_instance_queue.push_back(item);
    _last_queued_effect_instance[input.instance_id] = &_effect_instance_queue.back();
    return true;
}

bool NativeSimulationHost::queue_effect_pod_metric(
        int64_t instance_id, uint32_t generation, int32_t metric_id,
        int64_t revision, int64_t value, std::string &error) {
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    if (!_effect_pod_catalog.valid_metric_input(metric_id, revision)) {
        error = "effect_pod_metric_invalid";
        return false;
    }
    int64_t admitted_day = 0;
    auto admission = admit_effect_input(admitted_day);
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    if (_effect_metric_queue.size() >= RUNTIME_COMMAND_QUEUE_CAPACITY) {
        error = "effect_metric_capacity_exceeded";
        return false;
    }
    EffectPodMetricQueueItem item;
    item.admitted_day = admitted_day;
    item.instance_id = instance_id;
    item.generation = generation;
    item.metric_id = metric_id;
    item.revision = revision;
    item.value = value;
    _effect_metric_queue.push_back(item);
    return true;
}

bool NativeSimulationHost::queue_effect_pod_remove(
        int64_t instance_id, uint32_t generation, std::string &error) {
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    int64_t admitted_day = 0;
    auto admission = admit_effect_input(admitted_day);
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    if (_effect_remove_queue.size() >= RUNTIME_COMMAND_QUEUE_CAPACITY) {
        error = "effect_remove_capacity_exceeded";
        return false;
    }
    EffectPodRemoveQueueItem item;
    item.admitted_day = admitted_day;
    if (!allocate_effect_input_sequence_locked(item.sequence, error)) return false;
    item.instance_id = instance_id;
    item.generation = generation;
    _effect_remove_queue.push_back(item);
    _last_queued_effect_instance.erase(instance_id);
    return true;
}

} // namespace pk
