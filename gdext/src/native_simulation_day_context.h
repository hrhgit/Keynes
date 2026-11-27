#pragma once

#include "native_simulation_host.h"
#include "native_simulation_day_support.h"

namespace pk {
struct NativeSimulationHost::DayExecution {
    RuntimeDayPlan &plan;
    const RuntimeEnvironmentSnapshot *&environment;
    const std::vector<RuntimeCommandPacket> &day_commands;
    std::vector<RuntimeCommandReceipt> &day_receipts;
    uint64_t admitted_submit_order;
    RuntimeDayCommit &commit;
    DayProgress &progress;
    std::vector<RuntimeCommandPacket> &gameplay_event_commands;
    const RuntimeEnvironmentSnapshot *climate_hashed_input = nullptr;
    uint64_t climate_hashed_input_hash = 0;
    bool climate_authority_requested = false;
    bool active_climate_ok = false;
    bool reuse_completed(RuntimeDomainPlan &stage) {
        const auto &result = progress.finished[static_cast<size_t>(stage.domain) - 1];
        if (!result.completed) return false;
        stage = result;
        commit.dirty_families |= stage.dirty_families;
        commit.work_units += stage.work_units;
        commit.completed_domain_mask |= runtime_domain_mask(stage.domain);
        ++commit.completed_stage_count;
        return true;
    }

    void remember_completed(const RuntimeDomainPlan &stage) {
        progress.finished[static_cast<size_t>(stage.domain) - 1] = stage;
    }
};
} // namespace pk
