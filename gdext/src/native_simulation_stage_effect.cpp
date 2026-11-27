#include "native_simulation_day_context.h"

namespace pk {
bool NativeSimulationHost::stage_effect(DayExecution &day, RuntimeDomainPlan &stage) {
    auto &plan = day.plan;
    auto &commit = day.commit;
    auto &climate_authority_requested = day.climate_authority_requested;
    auto &active_climate_ok = day.active_climate_ok;
    auto &gameplay_event_commands = day.gameplay_event_commands;
    if (stage.domain == RuntimeDomainId::EFFECT &&
        _mode.load(std::memory_order_acquire) ==
            RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::EFFECT)) != 0u) {
        // F8 ACTIVE independent Effect stage (Ideology order already passed
        // in the stage list). Park with Climate like Country/Modifier.
        if (climate_authority_requested && !active_climate_ok) {
            // Still absorb ENSURE registrations so technology instances are
            // present when Climate unblocks the Effect plan lane.
            std::string drain_error;
            drain_effect_transport_queues(drain_error, plan.context.day);
            note_day_park(runtime_domain_mask(RuntimeDomainId::EFFECT),
                          "effect_parked_climate_input");
            stage.completed = 0;
            return true;
        }
        const bool effect_stage_enabled =
            _effect_pod_configured &&
            !_effect_pod_catalog.definitions.empty();
        if (!effect_stage_enabled) {
            _effect_day_modifier_intents.clear();
            _effect_day_stage_ok = false;
            note_day_park(runtime_domain_mask(RuntimeDomainId::EFFECT),
                          _effect_pod_configured
                              ? "effect_catalog_empty"
                              : "effect_stage_not_configured");
            stage.completed = 0;
            return true;
        }
        std::string effect_error;
        const bool effect_ok = execute_effect_worker_stage(
            plan.context.day, plan.context.input_generation,
            commit, effect_error, &gameplay_event_commands);
        _effect_pod_ready.store(effect_ok, std::memory_order_release);
        const char *effect_reason = effect_ok ? "" :
            (effect_error.empty() ? "effect_pod_plan_failed"
                                  : effect_error.c_str());
        size_t effect_reason_index = 0;
        for (; effect_reason_index + 1 <
                   _effect_pod_fallback_reason.size() &&
               effect_reason[effect_reason_index] != '\0';
             ++effect_reason_index) {
            _effect_pod_fallback_reason[effect_reason_index].store(
                effect_reason[effect_reason_index],
                std::memory_order_release);
        }
        for (; effect_reason_index <
                   _effect_pod_fallback_reason.size();
             ++effect_reason_index) {
            _effect_pod_fallback_reason[effect_reason_index].store(
                '\0', std::memory_order_release);
        }
        if (effect_ok) {
            // Production ACTIVE Effect→Events: typed intents become
            // APPEND_BATCH commands for the subsequent EVENTS stage.
            // Events failure clears EVENTS completion and blocks COMMIT.
            resolve_pending_country_effect_peers();
            stage.completed = 1;
            commit.completed_domain_mask |=
                runtime_domain_mask(RuntimeDomainId::EFFECT);
            ++commit.completed_stage_count;
            if (!_effect_day_intents.empty()) {
                _active_evidence_mask.fetch_or(
                    runtime_domain_mask(RuntimeDomainId::EFFECT),
                    std::memory_order_release);
            }
            // Ideology transitions no longer receive a synthetic OK here:
            // under IDEOLOGY|MODIFIER the Modifier stage applies their rows
            // as atomic batches and derives the ACK from that result.
            // H8: same bridge for Trigger. Its effect intents are delivered
            // by this stage under a joint TRIGGER|EFFECT grant, so ACK them
            // here and let the next Trigger visit clear its barrier.
            if ((_requested_authority_mask.load(std::memory_order_acquire) &
                 runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT)) != 0u) {
                ack_trigger_intents_in_worker(plan.context.day);
            }
        } else {
            stage.completed = 0;
        }
        return true;
    }
    return true;
}
} // namespace pk
