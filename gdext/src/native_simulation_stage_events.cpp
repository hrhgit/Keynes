#include "native_simulation_day_context.h"
#include <algorithm>
#include <chrono>
#include <cstring>

namespace pk {
bool NativeSimulationHost::stage_events(DayExecution &day, RuntimeDomainPlan &stage) {
    auto &plan = day.plan;
    auto &commit = day.commit;
    auto &climate_authority_requested = day.climate_authority_requested;
    auto &active_climate_ok = day.active_climate_ok;
    if (stage.domain == RuntimeDomainId::EVENTS &&
        _mode.load(std::memory_order_acquire) ==
            RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::EVENTS)) != 0u) {
        // ACTIVE Events is the production journal and consumer-cursor
        // owner. A rejected packet is receipted and consumed; only a
        // plan/commit failure holds COMMIT at the sealed day.
        if (climate_authority_requested && !active_climate_ok) {
            stage.completed = 0;
            return true;
        }
        if (!run_day_events(day, plan.context.day, false)) {
            stage.completed = 0;
            commit.preflight_ok = 0;
            return true;
        }
        stage.work_units = day.progress.events_planned ? _events_authority.report().appended_events : 0;
        if (stage.work_units > 0u) {
            stage.dirty_families = RUNTIME_DIRTY_EVENTS;
            commit.dirty_families |= stage.dirty_families;
        }
        commit.work_units += stage.work_units;
        stage.completed = 1;
        commit.completed_domain_mask |=
            runtime_domain_mask(RuntimeDomainId::EVENTS);
        ++commit.completed_stage_count;
        return true;
    }
    return true;
}
} // namespace pk
