#include "economy_invariant_probe.h"
#include "economy_runtime.h"
#include "economy_runtime_building_investment_internal.h"
#include "parallel_dispatcher.h"
#include "runtime_switch_registry.h"

#include <cstring>
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
    economy->_signatures.resize(1);
    economy->_building_restart_margin_q16 = 0;
    economy->_worker_enabled = true;
    economy->_worker_task_cap = 4;
    economy->_worker_tasks_hint = 4;
    economy->_merchant_offsets.assign(cells + 1, 0);
    economy->_building_recovery_liquidation_eligible.assign(cells, 0);
    economy->_building_review_owner_vacancy.assign(cells, 0);
    economy->market_store().cell_to_market.assign(cells, -1);
    economy->population_store().clear(cells);
    // With no required labour or inputs and a break-even threshold, each
    // independent cell supplies exactly one approval to the plan join.
    for (int32_t cell = 0; cell < cells; ++cell) {
        NativeEconomyRuntime::BuildingGroup group;
        group.cell = cell;
        group.type_id = 0;
        group.count = 1;
        group.owner_signature_id = 0;
        group.operating_state = 1;
        group.severe_loss_cycles = 3;
        economy->append_building_group(group);
        const int32_t slot = economy->population_store().allocate_slot(cell, 0);
        economy->population_store().population.write_scalar(slot, 1);
        economy->_epoch_plan_cells.push_back(cell);
        economy->_building_cell_offsets.push_back(cell);
    }
    economy->_building_cell_offsets.push_back(cells);
    NativeEconomyRuntime::MarketResult market;
    auto *previous_market_sink = economy->_market_result_sink;
    economy->_market_result_sink = &market;
    const int32_t found = economy->find_cohort_slot(0, 0);
    economy->_market_result_sink = previous_market_sink;
    if (economy->_scan_calls_find_signature != 0 ||
        economy->_scan_steps_find_signature != 0) {
        error = "household_market_task_wrote_shared_cohort_lookup_counts";
        return false;
    }
    if (found < 0 || market.cohort_lookups.calls != 1 ||
        market.cohort_lookups.steps != 1) {
        error = "household_market_task_did_not_record_cohort_lookup";
        return false;
    }
    NativeEconomyRuntime::BuildingPlanResult task;
    if (!economy->prepare_building_economic_plan(
            0, 1, &economy->_epoch_plan_cells, task, error)) return false;
    if (task.recovery_approved != 1 ||
        economy->building_view(0).operating_state != 0) {
        error = "recovery_counter_fixture_did_not_approve";
        return false;
    }
    if (economy->_recovery_restarted != 0) {
        error = "building_plan_task_wrote_shared_recovery_count";
        return false;
    }
    const bool isolated_lookups = economy->_scan_calls_find_signature == 0 &&
        economy->_scan_steps_find_signature == 0;
    const bool streak_preserved = economy->building_view(0).severe_loss_cycles == 3;
    economy->building_at(0).operating_state = 1;
    economy->building_at(0).severe_loss_cycles = 3;
    economy->_scan_calls_find_signature = 0;
    economy->_scan_steps_find_signature = 0;
    if (!economy->evaluate_building_plan_range(0, cells, error)) return false;
    const char *serial = runtime_switch_value(RuntimeSwitch::PK_ECONOMY_STAGE_PLAN_SERIAL);
    const bool expect_parallel =
        parallel_has_real_worker_threads() && !(serial && std::strcmp(serial, "1") == 0);
    if (economy->_building_plan_worker_parallel_dispatches != (expect_parallel ? 1 : 0)) {
        error = "building_plan_did_not_dispatch_parallel_work";
        return false;
    }
    if (economy->_recovery_restarted != cells ||
        economy->_recovery_approved != cells) {
        error = "building_plan_did_not_reduce_all_recovery_counts";
        return false;
    }
    if (!isolated_lookups) {
        error = "building_plan_task_wrote_shared_cohort_lookup_counts";
        return false;
    }
    int64_t task_calls = 0;
    for (const auto &result : economy->_building_plan_results_scratch)
        task_calls += result.cohort_lookups.calls;
    // Every recovery candidate looks up its existing owner once for sorting.
    // Quote memoization can change how many additional lookups a task needs.
    // Each lookup visits exactly one cohort in this fixture.
    if (task.cohort_lookups.calls <= 0 ||
        task.cohort_lookups.steps != task.cohort_lookups.calls ||
        task_calls < cells || economy->_scan_calls_find_signature != task_calls ||
        economy->_scan_steps_find_signature != task_calls) {
        error = "building_plan_did_not_reduce_all_cohort_lookup_counts";
        return false;
    }
    if (!streak_preserved) {
        error = "building_plan_approval_cleared_the_vacancy_streak";
        return false;
    }
    return true;
}

bool EconomyInvariantProbe::run_building_portfolio_share(std::string &error) {
    auto economy = std::make_unique<NativeEconomyRuntime>();
    economy->_cell_count = 1;
    economy->market_store().market_count = 1;
    economy->market_store().cell_to_market.assign(1, 0);
    economy->_building_construction_candidate_offsets = {0};
    economy->_building_types.resize(2);
    economy->_investment_max_type_owner_share_q16 = NativeEconomyRuntime::Q16_ONE / 2;
    for (const int64_t first_slots : {2, 1}) {
        NativeEconomyRuntime::BuildingInvestmentCellContext review(0);
        review.cell_population = 10;
        review.employment_gap = 4;
        review.portfolio_size = 2;
        economy->_building_types[0].owner_slots_per_building = first_slots;
        economy->_building_types[1].owner_slots_per_building = 2;
        for (int32_t type = 0; type < 2; ++type) {
            auto &candidate = review.portfolio[type];
            candidate.plan.type_id = type;
            candidate.plan.sponsor = type;
            candidate.plan.max_batch_count = 1;
            candidate.plan.request.reason = NativeEconomyRuntime::INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP;
            candidate.willing_population = economy->_building_types[type].owner_slots_per_building;
            candidate.jobs_per_building = candidate.willing_population;
            candidate.desired_count = 1;
            candidate.score_q16 = 2 - type;
        }
        economy->investment_allocate_portfolio(review);
        // Equal pairs fit the cap. An indivisible 1:2 pair cannot fit, but
        // the highest ranked single project is within the existing rules.
        const bool balanced = first_slots == 2;
        if (review.portfolio[0].plan.allocated_count != 1 ||
            review.portfolio[1].plan.allocated_count != (balanced ? 1 : 0)) {
            error = balanced ? "balanced_investment_portfolio_trimmed"
                             : "indivisible_investment_portfolio_lost_single_project";
            return false;
        }
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
