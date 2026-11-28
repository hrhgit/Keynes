#include "economy_invariant_probe.h"
#include "economy_runtime.h"
#include "economy_runtime_building_investment_internal.h"
#include "parallel_dispatcher.h"
#include "runtime_switch_registry.h"

#include <cstring>
#include <cstdio>
#include <memory>

namespace pk {

bool EconomyInvariantProbe::run_building_plan_counter(std::string &error) {
    constexpr int32_t cells = 24;
    auto make_fixture = [cells] {
        auto economy = std::make_unique<NativeEconomyRuntime>();
        economy->_cell_count = cells;
        economy->_epoch_active = true;
        economy->_epoch_days = 1;
        economy->_current_day = 0;
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
        economy->_building_lifecycle.resize(cells);
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
            group.owner_vacancy_cycles = 2;
            group.vacant_buildings = 1;
            economy->append_building_group(group);
            const int32_t slot = economy->population_store().allocate_slot(cell, 0);
            economy->population_store().population.write_scalar(slot, 1);
            economy->_epoch_plan_cells.push_back(cell);
            economy->_building_cell_offsets.push_back(cell);
        }
        economy->_building_cell_offsets.push_back(cells);
        return economy;
    };
    auto economy = make_fixture();
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
    const auto &operating_state = economy->buildings_store().operating_state;
    const auto before_task = operating_state.mutation_revision();
    if (!economy->prepare_building_economic_plan(
            0, 1, &economy->_epoch_plan_cells, task, error)) return false;
    if (task.recovery_approved != 1 ||
        economy->building_view(0).operating_state != 0) {
        error = "recovery_counter_fixture_did_not_approve";
        return false;
    }
    if (operating_state.mutation_revision() != before_task) {
        error = "building_plan_task_touched_shared_operating_state_registry";
        return false;
    }
    if (economy->_recovery_restarted != 0) {
        error = "building_plan_task_wrote_shared_recovery_count";
        return false;
    }
    const bool isolated_lookups = economy->_scan_calls_find_signature == 0 &&
        economy->_scan_steps_find_signature == 0;
    const auto after_offer = economy->building_group_copy(0);
    const bool streak_preserved = after_offer.severe_loss_cycles == 3 &&
        after_offer.owner_vacancy_cycles == 2 && after_offer.vacant_buildings == 1;
    economy = make_fixture();
    const auto &parallel_state = economy->buildings_store().operating_state;
    auto serial_economy = make_fixture();
    serial_economy->_worker_enabled = false;
    const auto seal_opening = [](NativeEconomyRuntime &world) {
        auto &store = world.buildings_store();
        store.changes.seal();
        store.visit_registered_columns([](const auto &column) {
            for (const auto consumer : {EconomyChangeConsumer::Hash,
                    EconomyChangeConsumer::Audit, EconomyChangeConsumer::Publish}) {
                column.take_change_pages(consumer);
            }
        });
    };
    seal_opening(*economy);
    seal_opening(*serial_economy);
    if (!serial_economy->evaluate_building_plan_range(0, cells, error) ||
        !economy->evaluate_building_plan_range(0, cells, error)) return false;
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
    // All 24 cells flip the same tracked column in the same dirty page.
    // Compare every registered field plus the exact batch seen by consumers.
    const auto snapshot = [](RuntimeEconomyBuildingStore &store) {
        std::vector<uint64_t> state;
        store.visit_registered_columns([&](const auto &column) {
            state.push_back(column.field_id().key());
            state.push_back(column.size());
            for (const auto value : column) state.push_back(static_cast<uint64_t>(value));
            for (const auto consumer : {EconomyChangeConsumer::Hash,
                    EconomyChangeConsumer::Audit, EconomyChangeConsumer::Publish}) {
                const auto pages = column.take_change_pages(consumer);
                state.push_back(pages.size());
                state.insert(state.end(), pages.begin(), pages.end());
            }
        });
        return state;
    };
    if (snapshot(economy->buildings_store()) != snapshot(serial_economy->buildings_store())) {
        error = "building_plan_parallel_columns_or_change_pages_differ_from_serial";
        return false;
    }
    if (std::any_of(parallel_state.begin(), parallel_state.end(),
            [](auto value) { return value != 0; })) {
        error = "building_plan_did_not_reopen_every_cell";
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
    economy->_merchant_offsets = {0, 0};
    economy->_signatures.resize(2);
    auto &population = economy->population_store();
    population.clear(1);
    const int32_t sponsors[] = {population.allocate_slot(0, 0), population.allocate_slot(0, 1)};
    for (const int32_t sponsor : sponsors) population.population.write_scalar(sponsor, 5);
    economy->_investment_max_type_owner_share_q16 = NativeEconomyRuntime::Q16_ONE / 2;
    for (const int64_t first_slots : {2, 1}) {
        NativeEconomyRuntime::BuildingInvestmentCellContext review(0);
        review.market = 0;
        review.cell_population = 10;
        review.employment_gap = 4;
        review.portfolio_size = 2;
        economy->_building_types[0].owner_slots_per_building = first_slots;
        economy->_building_types[1].owner_slots_per_building = 2;
        for (int32_t type = 0; type < 2; ++type) {
            auto &candidate = review.portfolio[type];
            candidate.plan.type_id = type;
            candidate.plan.sponsor = sponsors[type];
            candidate.plan.owner_signature_id = type;
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
    for (const int64_t second_slots : {2, 3}) {
        NativeEconomyRuntime::BuildingInvestmentCellContext review(0);
        review.market = 0;
        review.cell_population = 10;
        review.employment_gap = second_slots == 2 ? 6 : 8;
        review.portfolio_size = 2;
        economy->_building_types[0].owner_slots_per_building = 1;
        economy->_building_types[1].owner_slots_per_building = second_slots;
        for (int32_t type = 0; type < 2; ++type) {
            auto &candidate = review.portfolio[type];
            candidate.plan.type_id = type;
            candidate.plan.sponsor = sponsors[type];
            candidate.plan.owner_signature_id = type;
            candidate.plan.max_batch_count = type == 0 ? second_slots : 2;
            candidate.plan.request.reason = NativeEconomyRuntime::INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP;
            candidate.jobs_per_building = economy->_building_types[type].owner_slots_per_building;
            candidate.willing_population = candidate.jobs_per_building * candidate.plan.max_batch_count;
            candidate.desired_count = candidate.plan.max_batch_count;
            // Prefer the seat-heavy type in the initial allocation; both
            // cases have a feasible alternative with equally divided seats.
            candidate.score_q16 = type == 0 ? 1 : 2;
        }
        economy->investment_allocate_portfolio(review);
        if (review.portfolio[0].plan.allocated_count != second_slots ||
            review.portfolio[1].plan.allocated_count != 1) {
            error = second_slots == 2 ? "feasible_investment_portfolio_1_to_2_missed"
                                      : "feasible_investment_portfolio_1_to_3_missed";
            return false;
        }
    }
    // Each of four candidates can supply plenty of labour and money. The
    // single crate shared by their identical recipes can pay for one lot.
    economy->_building_types.resize(4);
    economy->_good_ids = {"construction_test"};
    auto &market = economy->market_store();
    market.good_count = 1;
    market.stock.assign(1, 1000);
    market.price.assign(1, 1000);
    economy->_building_construction_goods = {{0, 1000}};
    economy->_building_construction_candidates = {{0, NativeEconomyRuntime::Q16_ONE}};
    economy->_building_construction_candidate_offsets = {0, 1};
    for (auto &type : economy->_building_types) {
        type.construction_begin = 0;
        type.construction_count = 1;
        type.owner_slots_per_building = 1;
    }
    economy->_signatures.resize(5);
    const int32_t large_sponsors[] = {sponsors[0], sponsors[1],
        population.allocate_slot(0, 2), population.allocate_slot(0, 3)};
    for (auto sponsor : large_sponsors) {
        population.population.write_scalar(sponsor, 100);
        population.funds.write_scalar(sponsor, 100000);
    }
    economy->_merchant_profession_id = 4;
    economy->_signatures[4].profession_id = 4;
    const int32_t merchant = population.allocate_slot(0, 4);
    population.population.write_scalar(merchant, 1);
    economy->_merchant_offsets = {0, 1};
    economy->_merchant_slots = {merchant};
    for (const int64_t max_batch : {8, 100}) {
        NativeEconomyRuntime::BuildingInvestmentCellContext review(0);
        review.market = 0;
        review.cell_population = 400;
        review.employment_gap = 400;
        review.portfolio_size = 4;
        for (int32_t type = 0; type < review.portfolio_size; ++type) {
            auto &candidate = review.portfolio[type];
            candidate.plan.type_id = type;
            candidate.plan.sponsor = large_sponsors[type];
            candidate.plan.owner_signature_id = type;
            candidate.plan.max_batch_count = max_batch;
            candidate.plan.funding_capital = 1000;
            candidate.willing_population = max_batch;
            candidate.transferable_capital = 100000;
            candidate.jobs_per_building = 1;
            candidate.desired_count = max_batch;
            candidate.score_q16 = 4 - type;
        }
        economy->investment_allocate_portfolio(review);
        std::printf("investment shortage fixture: batch=%lld trials=%llu types=%d first=%lld\n",
            static_cast<long long>(max_batch),
            static_cast<unsigned long long>(review.search_trials), review.active_types,
            static_cast<long long>(review.portfolio[0].plan.allocated_count));
        if (review.active_types != 1 || review.portfolio[0].plan.allocated_count != 1 ||
            market.stock[0] != 1000 || population.funds[large_sponsors[0]] != 100000) {
            error = "investment_shortage_changed_the_ranked_single_project";
            return false;
        }
        if (review.search_trials > 32) {
            error = "investment_shortage_search_ignored_shared_capacity";
            return false;
        }
    }
    // Each lot needs both materials. Only three complete affordable recipes exist.
    // The other stocks can supply the entire nominal batch at unaffordable prices.
    constexpr int goods = 18;
    economy->_good_ids.resize(goods);
    market.good_count = goods;
    market.stock.assign(goods, 1'000'000);
    market.price.assign(goods, 100'000);
    economy->_building_construction_goods = {{0, 1000}, {1, 1000}};
    economy->_building_construction_candidates.clear();
    for (int group = 0; group < 2; ++group) {
        market.stock.write_scalar(group, 3000);
        market.price.write_scalar(group, 1);
        for (int good = group; good < goods; good += 2)
            economy->_building_construction_candidates.push_back({good, NativeEconomyRuntime::Q16_ONE});
    }
    economy->_building_construction_candidate_offsets = {0, goods / 2, goods};
    for (const int batch : {32, 256}) {
        NativeEconomyRuntime::BuildingInvestmentCellContext review(0);
        review.market = 0;
        review.cell_population = 2000;
        review.employment_gap = 2000;
        review.portfolio_size = 2;
        for (int i = 0; i < 2; ++i) {
            const int slots = i == 0 ? 1 : 3;
            auto &type = economy->_building_types[i];
            type.owner_slots_per_building = slots;
            type.construction_count = 2;
            auto &candidate = review.portfolio[i];
            candidate.plan.type_id = i;
            candidate.plan.sponsor = large_sponsors[i];
            candidate.plan.owner_signature_id = i;
            candidate.plan.max_batch_count = batch;
            candidate.plan.funding_capital = 2;
            candidate.transferable_capital = 100000;
            candidate.willing_population = slots * batch;
            population.population.write_scalar(large_sponsors[i], slots * batch);
            candidate.jobs_per_building = slots;
            candidate.desired_count = batch;
            candidate.score_q16 = 2 - i;
        }
        economy->investment_allocate_portfolio(review);
        std::printf("tight material budget: batch=%d trials=%llu quotes=%llu allocation=%lld,%lld\n",
            batch, (unsigned long long)review.search_trials, (unsigned long long)review.material_quotes,
            (long long)review.portfolio[0].plan.allocated_count, (long long)review.portfolio[1].plan.allocated_count);
        if (review.active_types != 1 || review.portfolio[0].plan.allocated_count != 2 ||
                review.portfolio[1].plan.allocated_count != 0 || market.stock[0] != 3000 ||
                market.stock[1] != 3000 || population.funds[large_sponsors[0]] != 100000) {
            error = "investment_tight_budget_changed_selection";
            return false;
        }
        if (review.material_quotes > 80) {
            error = "investment_tight_budget_requoted_unaffordable_buildings";
            return false;
        }
    }
    // Shared shelves and equal rounded prices can change the next recipe.
    // Compare every affordable prefix with individual lots and one closing bill.
    market.good_count = 3;
    economy->_good_ids.resize(3);
    economy->_building_construction_goods = {{0, 140}, {1, 300}};
    economy->_building_construction_candidates = {{0, 65536}, {1, 65536},
        {2, 32768}, {1, 65536}, {0, 32768}};
    economy->_building_construction_candidate_offsets = {0, 3, 5};
    for (int price : {1, 4, 7}) {
        market.price.assign(std::vector<int32_t>{price, 3, 1});
        for (int cheap : {0, 280, 2460}) {
            const std::vector<int64_t> opening{cheap, 2210, 3210};
            for (int funding : {0, 1, 2, 4}) {
                int64_t sat = 0, expected = 0;
                auto per_lot = opening;
                NativeEconomyRuntime::GoodsBill bill;
                for (int n = 1; n <= 16; ++n) {
                    NativeEconomyRuntime::ConstructionMaterialPlan unit;
                    if (!economy->plan_construction_materials(0, 0, 1, 65536,
                            unit, nullptr, &per_lot)) break;
                    for (size_t j = 0; j < unit.good_ids.size(); ++j)
                        bill.add(unit.quantities[j], market.price[unit.good_ids[j]], sat);
                    if (bill.charged <= n * funding) expected = n;
                }
                auto batch = opening;
                NativeEconomyRuntime::ConstructionMaterialPlan material;
                const auto result = economy->quote_construction_lots(0, 0, 65536, batch, 16,
                    funding, material, nullptr);
                if (result != expected || batch != per_lot || material.total_cost != bill.charged ||
                    economy->construction_material_capacity(0, 0, 65536, opening, 16, funding) < expected) {
                    error = "batched_material_quote_differs_from_single_lots";
                    return false;
                }
            }
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
    using Review = NativeEconomyRuntime::BuildingLifecycleReview;
    runtime._building_lifecycle.resize(4);
    runtime._building_lifecycle[0].employment = Review::Employment::Reopen;
    runtime._building_lifecycle[2].employment = Review::Employment::Reopen;
    runtime._building_funded_capacity_q16 = {1, 2, 3, 4};
    const int32_t first_live_role = runtime.building_view(1).employee_fill_begin;
    runtime._building_employee_filled.write_scalar(first_live_role, 7);
    runtime.building_at(1).filled_owner = 1;
    runtime.change_visiting_owner(1, 2, 1);
    runtime.building_at(0).count = 0;
    std::vector<int32_t> changed_cells;
    if (!runtime.commit_ready_construction(changed_cells) ||
        runtime._building_cell_offsets != std::vector<int32_t>{0, 2, 3} ||
        runtime.building_view(0).type_id != 1 ||
        runtime.building_owner_seats(runtime.building_view(0), 2) != 1 ||
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
        runtime._building_lifecycle.size() != 3 ||
        runtime._building_lifecycle[0].employment != Review::Employment::None ||
        runtime._building_lifecycle[1].employment != Review::Employment::Reopen ||
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
        runtime.building_owner_seats(runtime.building_view(1), 2) != 1 ||
        runtime.building_view(1).employee_fill_begin != first_live_role ||
        cooldowns.size() != 1 || cooldowns[0].source_group != 1 ||
        cooldowns[0].target_group != 2 || cooldowns[0].until_day != 40) {
        error = "building_insert_rebound_an_existing_owner_mobility_row";
        return false;
    }
    // Rest-day employment fills seven of eight previously confirmed empty
    // units. A failed purchase releases the seven without changing that fact.
    auto lot = runtime.building_at(1);
    lot.count = 8;
    lot.filled_owner = 7;
    lot.owner_vacancy_cycles = 1;
    lot.vacant_buildings = 8;
    lot.operating_state = 0;
    runtime._building_types[lot.type_id].owner_profession_id = 1;
    runtime._building_severe_loss_cycles = 1;
    runtime._building_lifecycle[1].employment = Review::Employment::Reopen;
    runtime.observe_building_employment(1, 2, false, {8});
    NativeEconomyRuntime::ProductionResult stalled;
    runtime.finish_building_reopenings(1, 2, stalled);
    runtime.review_expired_building_vacancy(1);
    runtime.review_recovery_building_group(1);
    if (!stalled.released_reopening_jobs || runtime.building_view(1).count != 7 ||
            runtime.building_view(1).filled_owner != 0 || runtime.building_view(1).vacant_buildings != 0) {
        error = "building_retired_more_than_latest_confirmed_rest_day_vacancy";
        return false;
    }
    // A registered family's member works elsewhere. Holding title does not
    // let the family claim the seat of an actual visiting proprietor.
    runtime._signatures.resize(3);
    runtime.population_store().clear(2);
    const int registered = runtime.population_store().allocate_slot(0, 0);
    const int visitor = runtime.population_store().allocate_slot(0, 2);
    for (int slot : {registered, visitor}) runtime.population_store().population.write_scalar(slot, 1);
    runtime.building_at(1).filled_owner = 1;
    runtime.change_visiting_owner(1, 2, 1);
    runtime._building_types[runtime.building_view(1).type_id].owner_slots_per_building = 1;
    runtime._family_runtime_mode = 2;
    runtime._family_building_offsets = {0, 0, 1, 1, 1};
    runtime._family_building_edge_indices = {0};
    runtime._family_cohort_offsets.assign(runtime.population_store().active.size() + 1, 1);
    std::fill_n(runtime._family_cohort_offsets.begin(), registered + 1, 0);
    runtime._family_cohort_edge_indices = {0};
    runtime.family_memberships().push_back({1, runtime.population_store().handle_for_slot(registered), 1});
    runtime.family_ownerships().push_back({1, 1, 1, 0});
    runtime.attribute_family_owner_employment_for_cell(0);
    if (runtime.family_ownerships()[0].filled_owner != 0 || runtime.building_view(1).filled_owner != 1) {
        error = "unseated_registered_family_claimed_a_visiting_owner";
        return false;
    }
    return true;
}

} // namespace pk
