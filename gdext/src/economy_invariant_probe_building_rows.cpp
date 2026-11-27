#include "economy_invariant_probe.h"
#include "economy_runtime.h"

#include <memory>

namespace pk {

bool EconomyInvariantProbe::run_building_plan_counter(std::string &error) {
    constexpr int32_t cells = 24;
    auto economy = std::make_unique<NativeEconomyRuntime>();
    economy->_cell_count = cells;
    economy->_epoch_active = true;
    economy->_epoch_days = 1;
    economy->_epoch_country_count = 1;
    economy->_epoch_cell_country.assign(cells, 0);
    economy->_epoch_country_building_available = {1};
    economy->_building_types.resize(1);
    economy->_building_restart_margin_q16 = 0;
    economy->_worker_tasks_hint = 4;
    economy->_merchant_offsets.assign(cells + 1, 0);
    economy->_building_recovery_liquidation_eligible.assign(cells, 0);
    economy->market_store().cell_to_market.assign(cells, -1);
    economy->population_store().clear(cells);
    // With no required labour or inputs and a break-even threshold, each
    // independent cell supplies exactly one approval to the plan join.
    for (int32_t cell = 0; cell < cells; ++cell) {
        NativeEconomyRuntime::BuildingGroup group;
        group.cell = cell;
        group.type_id = 0;
        group.count = 1;
        group.operating_state = 1;
        economy->append_building_group(group);
        economy->_epoch_plan_cells.push_back(cell);
        economy->_building_cell_offsets.push_back(cell);
    }
    economy->_building_cell_offsets.push_back(cells);
    NativeEconomyRuntime::BuildingPlanResult task;
    if (!economy->prepare_building_economic_plan(
            0, 1, &economy->_epoch_plan_cells, task, error)) return false;
    if (task.recovery_approved != 1 ||
        economy->building_view(0).pending_operating_state != 0) {
        error = "recovery_counter_fixture_did_not_approve";
        return false;
    }
    if (economy->_recovery_restarted != 0) {
        error = "building_plan_task_wrote_shared_recovery_count";
        return false;
    }
    economy->building_at(0).pending_operating_state = 255;
    if (!economy->evaluate_building_plan_range(0, cells, error)) return false;
    // Each cell in this fixture has one building with no inputs, jobs or
    // outputs, so the planner estimates nine units of work per cell.
    const bool expect_parallel =
        economy->building_plan_uses_worker_pool(cells, cells * 9);
    if (economy->_recovery_restarted != cells ||
        economy->_recovery_approved != cells ||
        economy->_building_plan_worker_parallel_dispatches !=
            (expect_parallel ? 1 : 0)) {
        error = "building_plan_did_not_reduce_all_recovery_counts";
        return false;
    }
    return true;
}

bool EconomyInvariantProbe::run_building_row_references(std::string &error) {
    auto economy = std::make_unique<NativeEconomyRuntime>();
    auto &runtime = *economy;
    runtime._cell_count = 2;
    runtime.market_store().cell_to_market.assign(2, -1);
    runtime._market_signals.clear(2);
    runtime._labor_signals.clear(2);
    runtime._building_types.resize(3);
    runtime._building_employee_roles.resize(1);
    for (auto &type : runtime._building_types) type.employee_count = 1;

    NativeEconomyRuntime::BuildingGroup group;
    group.cell = 0;
    group.owner_signature_id = 0;
    group.count = 1;
    for (int32_t type = 0; type < 3; ++type) {
        group.type_id = type;
        runtime.append_building_group(group);
    }
    group.cell = 1;
    runtime.append_building_group(group);
    runtime.rebuild_building_role_storage();

    runtime._owner_mobility_cooldowns = {{0, 1, 2, 40}, {0, 0, 2, 50}};
    runtime._person_building_offsets = {0, 1, 2, 2, 3};
    runtime._person_building_indices = {10, 20, 30};
    runtime._building_reopened_groups = {0, 2};
    runtime._building_funded_capacity_q16 = {1, 2, 3, 4};
    const int32_t first_live_role = runtime.building_view(1).employee_fill_begin;
    runtime._building_employee_filled.write_scalar(first_live_role, 7);
    runtime.building_at(0).count = 0;
    std::vector<int32_t> changed_cells;
    if (!runtime.commit_ready_construction(changed_cells) ||
        runtime._building_cell_offsets != std::vector<int32_t>{0, 2, 3} ||
        runtime.building_view(0).type_id != 1 ||
        runtime.building_view(0).employee_fill_begin != first_live_role ||
        runtime._building_employee_filled[first_live_role] != 7) {
        error = "building_compaction_moved_or_lost_the_wrong_role";
        return false;
    }
    const auto &cooldowns = runtime._owner_mobility_cooldowns;
    if (cooldowns.size() != 1 || cooldowns[0].cell != 0 ||
        cooldowns[0].source_group != 0 || cooldowns[0].target_group != 1 ||
        cooldowns[0].until_day != 40) {
        error = "building_compaction_left_stale_owner_mobility_rows";
        return false;
    }
    if (runtime._person_building_offsets != std::vector<int32_t>{0, 1, 1, 2} ||
        runtime._person_building_indices != std::vector<int32_t>{20, 30} ||
        runtime._building_reopened_groups != std::vector<int32_t>{1} ||
        runtime._building_funded_capacity_q16 != std::vector<int64_t>{2, 3, 4}) {
        error = "building_compaction_left_stale_group_ranges";
        return false;
    }

    group.cell = 0;
    group.type_id = 0;
    runtime.append_building_group(group);
    runtime.rebuild_building_role_storage();
    if (runtime._building_cell_offsets != std::vector<int32_t>{0, 3, 4} ||
        runtime.building_view(0).type_id != 0 ||
        runtime._building_employee_filled[runtime.building_view(0).employee_fill_begin] != 0 ||
        runtime.building_view(1).employee_fill_begin != first_live_role ||
        cooldowns.size() != 1 || cooldowns[0].source_group != 1 ||
        cooldowns[0].target_group != 2 || cooldowns[0].until_day != 40) {
        error = "building_insert_rebound_an_existing_owner_mobility_row";
        return false;
    }
    return true;
}

} // namespace pk
