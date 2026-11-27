#include "economy_authority_transfer.h"
#include "economy_invariant_probe.h"
#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#endif
#include "native_simulation_host.h"
#include "native_simulation_day_context.h"
#include "runtime_module_descriptor.h"
#include <cassert>
#include "country_core_apply.h"
#include "country_ai_runtime.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "effect_runtime.h"
#include "trigger_runtime.h"
#include "ideology_runtime.h"
#include "runtime_economy_ecp2.h"
#include "native_parallel_executor.h"
#include "runtime_climate_parity.h"
#include "runtime_switch_registry.h"
#include "pk_log.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <exception>
#include <limits>
#include <type_traits>
#include <unordered_set>

#if defined(_WIN32)
#include <windows.h>
#endif

#include "native_simulation_host_support.h"

namespace pk {

void NativeSimulationHost::attach_effect_adapter(
        EffectRuntime *effect, NativeCountryRuntime *country, TriggerRuntime *trigger,
        NativeIdeologyRuntime *ideology) {
    _effect_adapter_runtime = effect;
    _effect_adapter_country = country;
    _trigger_delivery = {};
    _trigger_delivery.runtime = trigger;
    _trigger_delivery.ideology = ideology;
    if (trigger != nullptr) _trigger_delivery.initial_view = std::make_shared<TriggerRuntime>(*trigger);
    if (ideology != nullptr) {
        ideology->attach_modifier_runtime(_economy_modifier_view);
        _trigger_delivery.initial_ideology_view = capture_ideology_read_view();
    }
    if (effect != nullptr) {
        effect->begin_executor_transaction_namespace();
    }
    std::atomic_store(&_published_era_reward, capture_era_reward());
}

std::shared_ptr<const RuntimeEffectReadView>
NativeSimulationHost::latest_effect_read_view() const {
    const auto commit = std::atomic_load(&_latest_commit);
    return commit && commit->day_tail ? commit->day_tail->effect : nullptr;
}

const char *NativeSimulationHost::stage_effect_adapter(DayExecution &day) {
    if (_effect_adapter_runtime == nullptr) return nullptr;
    auto &effect = *_effect_adapter_runtime;
    const auto &snapshot = _effect_pod_authority.snapshot();
    std::string error;
    if (snapshot.generation > effect.pod_snapshot_generation() &&
        !effect.apply_pod_snapshot(snapshot, error)) {
        pk::log_error("[effect] executor adapter snapshot: %s", error.c_str());
        return "effect_executor_adapter_snapshot_failed";
    }
    RuntimeDomainIntent intent;
    while (poll_effect_pod_intent(intent)) {
        if (intent.target_domain == static_cast<uint16_t>(RuntimeDomainId::MODIFIER))
            continue;
        RuntimeDomainAck ack;
        ack.request_id = intent.request_id;
        ack.transaction_id = intent.request_id;
        ack.target_handle = intent.target_handle;
        ack.target_generation = intent.target_generation;
        ack.domain = intent.target_domain;
        ack.code = RuntimeDomainAckCode::OK;
        ack.effective_day = intent.effective_day;
        ack.producer_id = intent.producer_id;
        ack.sequence = intent.sequence;
        if (!submit_effect_pod_ack(ack, error)) return "effect_executor_adapter_ack_failed";
    }
    if (_effect_adapter_country != nullptr) {
        effect.dispatch_native_country(_effect_adapter_country);
        effect.ack_native_country(_effect_adapter_country);
        effect.settle_orphaned_native_country_acks();
    }
    if (_economy_production_runtime != nullptr) {
        effect.dispatch_native_economy(_economy_production_runtime);
        effect.ack_native_economy(_economy_production_runtime);
    }
    if (const char *error = settle_era_rewards(day)) return error;
    auto view = std::make_shared<RuntimeEffectReadView>();
    view->report = effect.report();
    const bool country_pending = _effect_adapter_country != nullptr &&
        _effect_adapter_country->has_pending_effect_commands();
    const bool economy_pending = _economy_production_runtime != nullptr &&
        _economy_production_runtime->has_pending_effect_commands();
    const bool colonization_pending = effect.has_pending_family_colonization_transactions();
    view->adapters["country_pending"] = country_pending;
    view->adapters["economy_pending"] = economy_pending;
    view->adapters["colonization_pending"] = colonization_pending;
    view->adapters["idle"] = !country_pending && !economy_pending && !colonization_pending;
    if (!_executor_day_tail) _executor_day_tail = std::make_shared<RuntimeDayTail>();
    _executor_day_tail->effect = std::move(view);
    _executor_day_tail->era_reward = capture_era_reward();
    return nullptr;
}

bool NativeSimulationHost::configure_modifier_pod(
        const RuntimeModifierPodCatalog &catalog, std::string &error) {
    const RuntimeWorkerState worker_state = state();
    if (worker_state != RuntimeWorkerState::STOPPED &&
        worker_state != RuntimeWorkerState::FAULTED) {
        error = "modifier_pod_configure_while_running";
        return false;
    }
    if (!_modifier_pod_authority.configure(catalog, error)) {
        _modifier_pod_configured = false;
        return false;
    }
    _modifier_pod_catalog = catalog;
    _modifier_pod_catalog.catalog_hash = _modifier_pod_authority.catalog_hash();
    _modifier_pod_configured = true;
    // Key→id binding is installed by the caller after configure; drop any
    // previous catalog's hashes so a half-init cannot resolve to stale ids.
    _modifier_definition_id_by_key_hash.clear();
    return true;
}

void NativeSimulationHost::set_modifier_definition_key_hashes(
        const std::vector<std::pair<uint64_t, int32_t>> &entries) {
    _modifier_definition_id_by_key_hash.clear();
    _modifier_definition_id_by_key_hash.reserve(entries.size());
    for (const auto &entry : entries) {
        if (entry.first == 0 || entry.second < 0) continue;
        _modifier_definition_id_by_key_hash.emplace(entry.first, entry.second);
    }
}

int32_t NativeSimulationHost::resolve_modifier_definition_id_for_effect_intent(
        const RuntimeDomainIntent &intent) const {
    // Preferred: Effect command definition_key_hash → Modifier catalog id.
    if (_effect_pod_configured && intent.request_id != 0) {
        const auto &snapshot = _effect_pod_authority.snapshot();
        for (const auto &transaction : snapshot.transactions) {
            if (static_cast<uint64_t>(transaction.transaction_id) !=
                intent.request_id) {
                continue;
            }
            const uint64_t ordinal = intent.sequence - transaction.fire_sequence * 16u;
            if (ordinal >= transaction.command_count) break;
            const size_t command_index =
                static_cast<size_t>(transaction.command_begin) + ordinal;
            if (command_index >= snapshot.command_arena.size()) break;
            const auto &command = snapshot.command_arena[command_index];
            if (command.action != RuntimeEffectPodAction::MODIFIER_COMMAND)
                break;
            if (command.definition_key_hash != 0) {
                const auto found = _modifier_definition_id_by_key_hash.find(
                    command.definition_key_hash);
                if (found != _modifier_definition_id_by_key_hash.end())
                    return found->second;
            }
            break;
        }
    }
    // Legacy: payload[0] already carries a dense Modifier definition_id.
    if (intent.payload[0] > 0 &&
        intent.payload[0] <= static_cast<int64_t>(
            std::numeric_limits<int32_t>::max())) {
        return static_cast<int32_t>(intent.payload[0]);
    }
    return -1;
}

void NativeSimulationHost::collect_day_modifier_intents() {
    for (auto &intent : _effect_day_intents) {
        if (intent.target_domain != static_cast<uint16_t>(RuntimeDomainId::MODIFIER)) continue;
        if (intent.payload[0] <= 0) {
            const int32_t id = resolve_modifier_definition_id_for_effect_intent(intent);
            if (id >= 0) intent.payload[0] = id;
        }
        _effect_day_modifier_intents.push_back(intent);
    }
}

uint32_t NativeSimulationHost::ack_effect_events_intents_in_worker(
        const std::vector<RuntimeDomainIntent> &intents) {
    if (!_effect_pod_configured || intents.empty()) return 0;
    std::vector<RuntimeDomainAck> acks;
    acks.reserve(intents.size());
    for (const RuntimeDomainIntent &intent : intents) {
        if (intent.target_domain !=
            static_cast<uint16_t>(RuntimeDomainId::EVENTS)) {
            continue;
        }
        RuntimeDomainAck ack;
        ack.request_id =
            intent.request_id != 0 ? intent.request_id : intent.source_id;
        ack.transaction_id = ack.request_id;
        ack.target_handle = intent.target_handle;
        ack.target_generation = intent.target_generation;
        ack.domain = static_cast<uint16_t>(RuntimeDomainId::EVENTS);
        ack.code = RuntimeDomainAckCode::OK;
        ack.effective_day = intent.effective_day;
        ack.producer_id = intent.producer_id;
        ack.sequence = intent.sequence;
        acks.push_back(ack);
    }
    if (acks.empty()) return 0;
    std::string error;
    if (!_effect_pod_authority.apply_acks(acks, error)) {
        // Soft: leave Events bit for the main-thread pump / next retry.
        return 0;
    }
    _effect_pod_ack_count.store(
        _effect_pod_ack_count.load(std::memory_order_relaxed) +
            static_cast<uint32_t>(acks.size()),
        std::memory_order_release);
    _effect_pod_state_hash.store(
        _effect_pod_authority.snapshot().deterministic_state_hash,
        std::memory_order_release);
    return static_cast<uint32_t>(acks.size());
}

bool NativeSimulationHost::configure_effect_pod(
        const RuntimeEffectPodCatalog &catalog, std::string &error) {
    const RuntimeWorkerState worker_state = state();
    if (worker_state != RuntimeWorkerState::STOPPED &&
        worker_state != RuntimeWorkerState::FAULTED) {
        error = "effect_pod_configure_while_running";
        return false;
    }
    RuntimeEffectPodAuthority candidate;
    if (!candidate.configure(catalog, error)) {
        return false;
    }
    _effect_pod_authority = std::move(candidate);
    _effect_pod_catalog = catalog;
    _effect_pod_catalog.catalog_hash = _effect_pod_authority.catalog_hash();
    _effect_pod_configured = true;
    {
        std::lock_guard<std::mutex> lock(_effect_transport_mutex);
        _effect_instance_queue.clear();
        _effect_metric_queue.clear();
        _effect_remove_queue.clear();
        _effect_intents.clear();
        _effect_acks.clear();
    }
    _effect_day_modifier_intents.clear();
    _effect_day_stage_ok = false;
    return true;
}

bool NativeSimulationHost::encode_effect_pod_save(
        std::vector<uint8_t> &bytes, std::string &error) const {
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    _effect_pod_authority.serialize(bytes);
    if (bytes.empty()) {
        error = "effect_pod_save_encode_failed";
        return false;
    }
    return true;
}

bool NativeSimulationHost::restore_effect_pod_save(
        const uint8_t *bytes, size_t size, std::string &error) {
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    RuntimeEffectPodAuthority candidate;
    if (!candidate.configure(_effect_pod_catalog, error)) return false;
    if (!candidate.restore(bytes, size, error)) return false;
    _effect_pod_authority = std::move(candidate);
    return true;
}

bool NativeSimulationHost::effect_has_daily_input_fence() const noexcept {
    constexpr uint32_t tax_domains = runtime_domain_mask(RuntimeDomainId::ECONOMY) |
        runtime_domain_mask(RuntimeDomainId::MODIFIER);
    return _world_environment || (_mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) & tax_domains) == tax_domains);
}

RuntimeCommandAdmission NativeSimulationHost::admit_effect_input(int64_t &admitted_day) {
    if (on_worker_thread() || !effect_has_daily_input_fence())
        return RuntimeCommandAdmission(true);
    RuntimeCommandAdmission admission(_command_producer_mutex, _command_seal);
    admitted_day = std::max({command_seal_day(), frozen_command_day() + 1,
        _effect_input_sealed_day.load(std::memory_order_acquire) + 1});
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
    // Coalesce only with the queue tail, and only when that tail is still the
    // newest arrival. Re-ENSUREing the same identity several times per frame
    // must keep the newest payload (a stale level / next_due_day here is exactly
    // the "present=0, queued>0" class of bug). But if a retire landed after the
    // tail -- it lives in the *other* deque, so the tail alone cannot tell --
    // folding this upsert into the tail would replay it before the retire and
    // the instance would never come back.
    if (!_effect_instance_queue.empty()) {
        EffectPodInstanceQueueItem &tail = _effect_instance_queue.back();
        if (tail.sequence == _effect_transport_sequence &&
            tail.admitted_day == admitted_day &&
            tail.input.instance_id == input.instance_id &&
            tail.input.generation == input.generation) {
            tail.input = input;
            return true;
        }
    }
    if (_effect_instance_queue.size() >= RUNTIME_COMMAND_QUEUE_CAPACITY) {
        error = "effect_instance_capacity_exceeded";
        return false;
    }
    EffectPodInstanceQueueItem item;
    item.admitted_day = admitted_day;
    item.sequence = ++_effect_transport_sequence;
    item.input = input;
    _effect_instance_queue.push_back(item);
    return true;
}

bool NativeSimulationHost::queue_effect_pod_metric(
        int64_t instance_id, uint32_t generation, int32_t metric_id,
        int64_t revision, int64_t value, std::string &error) {
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
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
    item.sequence = ++_effect_transport_sequence;
    item.instance_id = instance_id;
    item.generation = generation;
    _effect_remove_queue.push_back(item);
    return true;
}

bool NativeSimulationHost::poll_effect_pod_intent(RuntimeDomainIntent &intent) {
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    if (_effect_intents.empty()) return false;
    intent = _effect_intents.front();
    _effect_intents.pop_front();
    return true;
}

bool NativeSimulationHost::submit_effect_pod_ack(
        const RuntimeDomainAck &ack, std::string &error) {
    if (ack.transaction_id == 0 && ack.request_id == 0) {
        error = "effect_ack_invalid";
        return false;
    }
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    if (_effect_acks.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) {
        error = "effect_ack_capacity_exceeded";
        return false;
    }
    _effect_acks.push_back(ack);
    {
        std::lock_guard<std::mutex> control_lock(_control_mutex);
        _country_peer_signal.fetch_add(1, std::memory_order_release);
    }
    _control_cv.notify_all();
    return true;
}

#include "native_simulation_host_effect_section_country_peers.inc"

bool NativeSimulationHost::drain_effect_transport_queues(std::string &error, int64_t open_day) {
    error.clear();
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    std::deque<EffectPodInstanceQueueItem> instances;
    std::deque<EffectPodMetricQueueItem> metrics;
    std::deque<EffectPodRemoveQueueItem> removes;
    std::vector<RuntimeDomainAck> acks;
    {
        std::lock_guard<std::mutex> lock(_effect_transport_mutex);
        const auto take_admitted = [open_day](auto &queue, auto &ready) {
            const auto first_moved = std::remove_if(queue.begin(), queue.end(), [&](auto &entry) {
                if (entry.admitted_day > open_day) return false;
                ready.push_back(std::move(entry));
                return true;
            });
            queue.erase(first_moved, queue.end());
        };
        take_admitted(_effect_instance_queue, instances);
        take_admitted(_effect_metric_queue, metrics);
        take_admitted(_effect_remove_queue, removes);
        acks.assign(_effect_acks.begin(), _effect_acks.end());
        _effect_acks.clear();
    }

    auto restore_remaining =
        [this](std::deque<EffectPodInstanceQueueItem> &left,
               std::deque<EffectPodMetricQueueItem> &metrics_left,
               std::deque<EffectPodRemoveQueueItem> &removes_left) {
            std::lock_guard<std::mutex> lock(_effect_transport_mutex);
            while (!left.empty()) {
                _effect_instance_queue.push_front(left.back());
                left.pop_back();
            }
            while (!metrics_left.empty()) {
                _effect_metric_queue.push_front(metrics_left.back());
                metrics_left.pop_back();
            }
            while (!removes_left.empty()) {
                _effect_remove_queue.push_front(removes_left.back());
                removes_left.pop_back();
            }
        };

    // Replay retires and upserts strictly in arrival order. Draining either
    // deque wholesale reorders "submit then retire" into "retire then submit",
    // and the retired instance comes back on the next plan.
    while (!removes.empty() || !instances.empty()) {
        const bool take_remove =
            !removes.empty() &&
            (instances.empty() ||
             removes.front().sequence < instances.front().sequence);
        if (take_remove) {
            const EffectPodRemoveQueueItem item = removes.front();
            removes.pop_front();
            if (_effect_pod_authority.remove_instance(item.instance_id,
                                                       item.generation, error)) {
                continue;
            }
            // EffectRuntime::retire_instance_pod returns true when no instance
            // matches: nothing was ever installed, so nothing Effect-owned can
            // be left behind. The worker authority reports "absent" and
            // "generation superseded" through the same token, and both are
            // benign here -- the queued retire simply has nothing to retire.
            if (error == "effect_pod_instance_stale_generation") {
                const auto &known = _effect_pod_authority.snapshot().instances;
                const bool id_present = std::any_of(
                    known.begin(), known.end(),
                    [&item](const RuntimeEffectPodInstance &instance) {
                        return instance.instance_id == item.instance_id;
                    });
                if (id_present)
                    _effect_retire_stale_count.fetch_add(
                        1, std::memory_order_release);
                else
                    _effect_retire_absent_count.fetch_add(
                        1, std::memory_order_release);
                error.clear();
                continue;
            }
            removes.push_front(item);
            restore_remaining(instances, metrics, removes);
            return false;
        }
        const EffectPodInstanceQueueItem queued = instances.front();
        instances.pop_front();
        RuntimeEffectPodInstanceInput input = queued.input;
        // Unscheduled map-generation inputs become due on the first open day.
        // An explicit future date belongs to the producer.
        input.next_due_day = std::max(input.next_due_day, open_day);
        if (!_effect_pod_authority.upsert_instance(input, error)) {
            // `effect_pod_instance_invalid` 是队列行自身的属性（program 越界 /
            // target_generation 为 0 / next_due_day 为负 / id 非正），排队再久也
            // 不会变合法。以前这里一律回插 + 返回 false：Effect 阶段每天在同一行
            // 失败，host 日再也提交不了，十二域 grant 一个都不授，新开局就冻在
            // 第 2 天。丢弃 + 记账 + 留字段快照，让游戏继续跑到能修产生端。
            // capacity / not_configured 仍然是暂态，保留回插。
            if (error == "effect_pod_instance_invalid") {
                _effect_instance_rejected_count.fetch_add(
                    1, std::memory_order_release);
                char detail[96];
                std::snprintf(detail, sizeof(detail),
                    "id=%lld gen=%u prog=%d th=%llu tg=%u due=%lld",
                    static_cast<long long>(input.instance_id),
                    static_cast<unsigned>(input.generation),
                    static_cast<int>(input.program_id),
                    static_cast<unsigned long long>(input.target_handle),
                    static_cast<unsigned>(input.target_generation),
                    static_cast<long long>(input.next_due_day));
                for (size_t i = 0; i + 1 < _effect_instance_reject_detail.size(); ++i) {
                    const char value = detail[i];
                    _effect_instance_reject_detail[i].store(
                        value, std::memory_order_release);
                    if (value == '\0') break;
                }
                _effect_instance_reject_detail[
                    _effect_instance_reject_detail.size() - 1].store(
                        '\0', std::memory_order_release);
                error.clear();
                continue;
            }
            EffectPodInstanceQueueItem retry = queued;
            retry.input = input;
            instances.push_front(retry);
            restore_remaining(instances, metrics, removes);
            return false;
        }
    }
    while (!metrics.empty()) {
        const EffectPodMetricQueueItem item = metrics.front();
        metrics.pop_front();
        if (!_effect_pod_authority.set_metric(
                item.instance_id, item.generation, item.metric_id,
                item.revision, item.value, error)) {
            // 实例已被换掉/丢弃，这条指标永远落不上去。回插会让 Effect 阶段
            // 每天同一处失败，与 ENSURE 的 effect_pod_instance_invalid 是同一类
            // 毒丸；丢弃并计数。
            if (error == "effect_pod_metric_stale_generation") {
                _effect_instance_rejected_count.fetch_add(
                    1, std::memory_order_release);
                error.clear();
                continue;
            }
            metrics.push_front(item);
            restore_remaining(instances, metrics, removes);
            return false;
        }
    }
    if (!acks.empty() &&
        !_effect_pod_authority.apply_acks(acks, error)) {
        return false;
    }
    return true;
}

bool NativeSimulationHost::execute_effect_worker_stage(
        int64_t day, uint64_t input_generation, RuntimeDayCommit &commit,
        std::string &error, std::vector<RuntimeCommandPacket> *event_packets) {
    (void)commit;
    error.clear();
    _effect_day_modifier_intents.clear();
    _effect_day_intents.clear();
    _effect_day_stage_ok = false;
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }

    if (!drain_effect_transport_queues(error, day)) return false;
    const auto &previous = _effect_pod_authority.snapshot();
    // The embedded Modifier path has no Events packet sink but may revisit
    // the same Effect commit while waiting for a Modifier receipt.
    const bool revisit = day >= 0 && day == previous.committed_day;
    if (revisit) {
        _effect_pod_authority.append_committed_pending_intents(day, _effect_day_intents);
        if (std::none_of(previous.instances.begin(), previous.instances.end(),
                [day](const auto &instance) { return instance.first_fire_due(day); })) {
            collect_day_modifier_intents();
            ack_effect_events_intents_in_worker(_effect_day_intents);
            _effect_day_stage_ok = true;
            return true;
        }
    }

    const auto plan_started = std::chrono::steady_clock::now();
    RuntimeEffectPodPlan plan;
    if (!_effect_pod_authority.plan_day(day, input_generation, plan, error, revisit)) {
        _effect_pod_authority.discard_plan();
        return false;
    }

    uint32_t emitted = 0;
    uint32_t managed_emitted = 0;
    uint32_t unmanaged_emitted = 0;
    std::array<int32_t, RUNTIME_EFFECT_INTENT_PROGRAM_REPORT_CAPACITY>
        emitted_program_ids{};
    emitted_program_ids.fill(-1);
    uint32_t emitted_program_count = 0;
    const auto replay_started = std::chrono::steady_clock::now();
    {
        std::lock_guard<std::mutex> lock(_effect_transport_mutex);
        if (plan.intents.size() > RUNTIME_DOMAIN_INTENT_CAPACITY - _effect_intents.size()) {
            _effect_pod_authority.discard_plan();
            error = "effect_intent_capacity_exceeded";
            return false;
        }
        if (!_effect_pod_authority.commit_day(plan, error)) {
            _effect_pod_authority.discard_plan();
            return false;
        }
        for (RuntimeDomainIntent intent : plan.intents) {
            // A receipt can outlive the Events journal's deduplication window.
            if (event_packets && !(intent.reserved_effect_flags & RUNTIME_DOMAIN_INTENT_EFFECT_REDELIVERY))
                event_packets->push_back(make_effect_intent_events_packet(intent, day));
            _effect_intents.push_back(intent);
            _effect_day_intents.push_back(intent);
            const int32_t source_instance_index =
                _effect_pod_authority.instance_index_for_id(
                    static_cast<int64_t>(intent.source_id));
            const auto &source_instances =
                _effect_pod_authority.snapshot().instances;
            const int32_t source_program_id =
                source_instance_index >= 0 &&
                    static_cast<size_t>(source_instance_index) <
                        source_instances.size()
                ? source_instances[static_cast<size_t>(source_instance_index)]
                    .program_id
                : -1;
            if (_effect_pod_authority.definition_is_managed(
                    source_program_id)) {
                ++managed_emitted;
            } else {
                ++unmanaged_emitted;
            }
            if (emitted_program_count < emitted_program_ids.size()) {
                emitted_program_ids[emitted_program_count++] =
                    source_program_id;
            }
            ++emitted;
        }
    }
    collect_day_modifier_intents();
    // PUBLISH_EVENT (technology.adopted) is published by the Events stage but
    // never ACKed there. Settle the Events bit in-worker so technology fire
    // does not wait on the main-thread Effect pump.
    ack_effect_events_intents_in_worker(_effect_day_intents);
    const double replay_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - replay_started).count();
    const RuntimeEffectPodSnapshot &snapshot = _effect_pod_authority.snapshot();
    _effect_pod_plan_ms.store(
        std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - plan_started).count(),
        std::memory_order_release);
    _effect_pod_replay_ms.store(replay_ms, std::memory_order_release);
    _effect_pod_state_hash.store(snapshot.deterministic_state_hash,
                                 std::memory_order_release);
    _effect_pod_snapshot_generation.store(snapshot.generation,
                                          std::memory_order_release);
    _effect_pod_intent_count.store(emitted, std::memory_order_release);
    _effect_pod_managed_intent_count.store(
        managed_emitted, std::memory_order_release);
    _effect_pod_unmanaged_intent_count.store(
        unmanaged_emitted, std::memory_order_release);
    _effect_pod_program_intent_count.store(
        emitted_program_count, std::memory_order_release);
    for (uint32_t index = 0; index < emitted_program_ids.size(); ++index) {
        _effect_pod_intent_program_ids[index].store(
            index < emitted_program_count ? emitted_program_ids[index] : -1,
            std::memory_order_relaxed);
    }
    _effect_pod_transaction_count.store(
        static_cast<uint32_t>(snapshot.transactions.size()),
        std::memory_order_release);
    // ACKs are applied at the top of this stage via drain_effect_transport_queues.
    _effect_pod_ack_count.store(0u, std::memory_order_release);
    _effect_day_stage_ok = true;
    return true;
}

} // namespace pk
