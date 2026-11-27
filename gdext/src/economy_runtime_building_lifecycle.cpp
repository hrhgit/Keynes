#include "economy_runtime.h"
#include "runtime_switch_registry.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <numeric>

namespace pk {
namespace {

struct BuildingReviewCalendar {
    bool throttled;
    int32_t liquidation_period;
    int64_t liquidation_phase;
    int32_t mobility_period;
    bool mobility_spread;
};

const BuildingReviewCalendar &building_review_calendar() {
    static const auto calendar = [] {
        const auto enabled = runtime_switch_value(RuntimeSwitch::PK_ECONOMY_TRACK_B);
        const auto period = [](const char *value, int fallback, int limit) {
            const int parsed = value ? std::atoi(value) : 0;
            return parsed > 0 ? std::min(parsed, limit) : fallback;
        };
        const auto offset = runtime_switch_value(RuntimeSwitch::PK_ECONOMY_TRACK_B_RECOVERY_OFFSET);
        const int64_t parsed_offset = offset ? std::atoi(offset) : 0;
        const int32_t spread = period(
            runtime_switch_value(RuntimeSwitch::PK_ECONOMY_TRACK_B_MOBILITY_SPREAD), 1, 32);
        return BuildingReviewCalendar{
            !(enabled && std::strcmp(enabled, "0") == 0),
            period(runtime_switch_value(RuntimeSwitch::PK_ECONOMY_TRACK_B_COMMIT_CADENCE), 4, 30),
            parsed_offset != 0 ? std::abs(parsed_offset) : 1,
            spread > 1 ? spread : period(
                runtime_switch_value(RuntimeSwitch::PK_ECONOMY_TRACK_B_MOBILITY_CADENCE), 5, 30),
            spread > 1,
        };
    }();
    return calendar;
}

} // namespace

bool NativeEconomyRuntime::building_liquidation_due() const {
    const auto &calendar = building_review_calendar();
    return !calendar.throttled || cycle_phase(_current_day.get(),
        calendar.liquidation_phase, calendar.liquidation_period) == 0;
}

int64_t NativeEconomyRuntime::building_mobility_days(int32_t cell) const {
    const auto &calendar = building_review_calendar();
    const int64_t elapsed = std::max(1, _epoch_days.get());
    if (!calendar.throttled || calendar.mobility_period == 1) return elapsed;
    int32_t phase = calendar.mobility_spread ? cell % calendar.mobility_period : 0;
    if (locked_market_cycle_days() == 1) {
        // If the two calendars never meet, move the hiring phase by the
        // smallest positive offset that makes a shared review possible.
        // This keeps the original hiring frequency, budget and retirement dates.
        phase += cycle_phase(calendar.liquidation_phase, phase,
            std::gcd(calendar.liquidation_period, calendar.mobility_period));
    }
    return cycle_phase(_current_day.get(), phase, calendar.mobility_period) == 0
        ? elapsed * calendar.mobility_period : 0;
}

void NativeEconomyRuntime::review_expired_building_vacancy(int32_t g) {
    const auto group = building_view(static_cast<size_t>(g));
    if (group.filled_owner >= group.count ||
        group.severe_loss_cycles < _building_severe_loss_cycles.get()) return;
    auto &review = _building_lifecycle[g];
    review.retirement = BuildingLifecycleReview::Retirement::Vacancy;
    review.vacant_buildings = group.count - group.filled_owner;
}

void NativeEconomyRuntime::observe_building_employment(
        int32_t begin, int32_t end, bool mobility_due) {
    using Employment = BuildingLifecycleReview::Employment;
    const int32_t vacancy_limit = _building_severe_loss_cycles.get();
    for (int32_t g = begin; g < end; ++g) {
        auto &review = _building_lifecycle[g];
        if (review.employment == Employment::None) continue;
        const bool reopening = review.employment == Employment::Reopen;
        if (!reopening) review.employment = Employment::None;
        const auto view = building_view(static_cast<size_t>(g));
        if (view.count <= 0 || view.operating_state != 0) continue;
        const BuildingType &type = _building_types[view.type_id];
        if (type.owner_slots_per_building <= 0) continue;
        auto group = building_at(static_cast<size_t>(g));
        if (group.filled_owner >= group.count) {
            // A reopened facility first has to execute with its actual roster.
            if (!reopening) {
                group.severe_loss_cycles = 0;
                group.recovery_failed_reviews = 0;
            }
            continue;
        }
        const bool already_expired = group.severe_loss_cycles >= vacancy_limit;
        if (already_expired && mobility_due) review_expired_building_vacancy(g);
        group.severe_loss_cycles = static_cast<uint16_t>(std::min(
            vacancy_limit, static_cast<int32_t>(group.severe_loss_cycles) + 1));
        // The first suspension still precedes any retirement review. Once
        // reviewed, a partially staffed producer can use its existing seats.
        if (group.severe_loss_cycles >= vacancy_limit &&
            (!already_expired || group.filled_owner == 0)) {
            group.operating_state = 1;
            group.pending_operating_state = 255;
            group.recovery_cycles = 0;
            ++_loss_suspended_building_groups;
        }
    }
}

void NativeEconomyRuntime::finish_building_reopenings(
        int32_t begin, int32_t end, ProductionResult &result) {
    using Employment = BuildingLifecycleReview::Employment;
    for (int32_t g = begin; g < end; ++g) {
        auto &review = _building_lifecycle[g];
        if (review.employment != Employment::Reopen) continue;
        review.employment = Employment::None;
        auto group = building_at(static_cast<size_t>(g));
        if (group.last_output > 0 || group.last_resource_generated > 0) {
            if (group.filled_owner >= group.count) {
                group.severe_loss_cycles = 0;
                group.recovery_failed_reviews = 0;
            }
            continue;
        }
        if (group.operating_state != 1) {
            group.operating_state = 1;
            ++result.reopening_suspensions;
        }
        // Finish the period's cash and goods settlement before moving people
        // out of these jobs. Structural commit reconciles the changed cell.
        result.released_reopening_jobs |= group.filled_owner > 0;
        group.filled_owner = 0;
        const BuildingType &type = _building_types[group.type_id];
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const int32_t role = group.employee_fill_begin + r;
            if (_building_employee_filled[role] <= 0) continue;
            _building_employee_filled.write_scalar(role, 0, market_mutation_sink());
            result.released_reopening_jobs = true;
        }
    }
}

void NativeEconomyRuntime::review_recovery_building_group(int32_t g) {
    using Retirement = BuildingLifecycleReview::Retirement;
    if (g < 0 || static_cast<size_t>(g) >= _building_lifecycle.size() ||
        static_cast<size_t>(g) >= building_count()) return;
    const auto view = building_view(static_cast<size_t>(g));
    if (view.count <= 0 || view.cell < 0 || view.cell >= _cell_count.get() ||
        view.type_id < 0 || view.type_id >= static_cast<int32_t>(_building_types.size())) return;
    const BuildingType &type = _building_types[view.type_id];
    if (type.kind == 2 || type.kind == 3 ||
        type.owner_profession_id == _merchant_profession_id) return;

    const auto &review = _building_lifecycle[g];
    if (review.retirement == Retirement::None) {
        if (view.operating_state == 1 && view.recovery_failed_reviews != 0)
            building_at(static_cast<size_t>(g)).recovery_failed_reviews = 0;
        return;
    }
    if (review.retirement == Retirement::Retired) return;
    // Refuse an inconsistent cell range. It cannot prove that this cell
    // still has its original one-group retirement allowance available.
    const int32_t cell = view.cell;
    if (static_cast<size_t>(cell) + 1 >= _building_cell_offsets.size()) return;
    const int32_t begin = _building_cell_offsets[cell];
    const int32_t end = _building_cell_offsets[cell + 1];
    if (begin < 0 || begin > g || end <= g || end > static_cast<int32_t>(building_count()) ||
        building_view(static_cast<size_t>(begin)).cell != cell ||
        building_view(static_cast<size_t>(end - 1)).cell != cell) return;
    for (int32_t earlier = begin; earlier < g; ++earlier) {
        if (_building_lifecycle[earlier].retirement == Retirement::Retired) return;
    }

    auto group = building_at(static_cast<size_t>(g));
    int64_t confirmed_excess = review.vacant_buildings;
    if (review.retirement == Retirement::Unprofitable) {
        // The original economic retirement uses sales for an unprofitable
        // lot. A vacancy review has its own measured limit and never uses sales.
        int64_t unit_period_output = 0;
        for (int32_t i = 0; i < type.output_count; ++i) {
            const GoodAmount &output = _building_outputs[type.output_begin + i];
            unit_period_output = saturating_add(unit_period_output,
                effective_building_output_quantity(
                    group, output.good_id, output.quantity, Q16_ONE,
                    std::max<int64_t>(1, _epoch_days.get()), _saturation_count),
                _saturation_count);
        }
        unit_period_output = mul_div_sat(unit_period_output,
            std::max<int64_t>(1, group.planned_utilization_q16), Q16_ONE, _saturation_count);
        const int64_t supported_count = unit_period_output > 0
            ? std::min<int64_t>(group.count,
                saturating_add(std::max<int64_t>(0, group.last_sold),
                    unit_period_output - 1, _saturation_count) / unit_period_output)
            : 0;
        const int64_t unfilled = std::max<int64_t>(0, group.count - group.filled_owner);
        confirmed_excess = std::max(group.count - supported_count, unfilled);
    }
    group.recovery_failed_reviews = confirmed_excess > 0 ? 1 : 0;
    if (confirmed_excess <= 0) return;
    const int64_t max_retire = std::max<int64_t>(1,
        saturating_add(saturating_mul(group.count,
            _recovery_liquidation_max_share_q16.get(), _saturation_count),
            Q16_ONE - 1, _saturation_count) / Q16_ONE);
    const int64_t count_before = group.count;
    // Collapse v2 (2026-11-26): the last building may collapse as well. A
    // zero-count row stays in the store, the seats are released below and the
    // prune pass retires its modifier identity, so no consumer ever sees a live
    // lot of size zero.
    const int64_t retire_count = std::min(confirmed_excess, max_retire);
    if (retire_count <= 0) return;
    _building_lifecycle[g].retirement = Retirement::Retired;
    const int64_t principal_bad = retire_count == count_before
        ? group.merchant_debt_principal
        : mul_div_sat(group.merchant_debt_principal,
            retire_count, count_before, _saturation_count);
    const int64_t premium_bad = retire_count == count_before
        ? group.merchant_debt_premium
        : mul_div_sat(group.merchant_debt_premium,
            retire_count, count_before, _saturation_count);
    const int64_t bad_debt = saturating_add(
        principal_bad, premium_bad, _saturation_count);
    _merchant_credit_bad_debt = saturating_add(
        _merchant_credit_bad_debt, bad_debt, _saturation_count);
    _recovery_liquidated_buildings = saturating_add(
        _recovery_liquidated_buildings, retire_count, _saturation_count);
    group.merchant_debt_principal = std::max<int64_t>(
        0, group.merchant_debt_principal - principal_bad);
    group.merchant_debt_premium = std::max<int64_t>(
        0, group.merchant_debt_premium - premium_bad);
    _investment_employment_cells.push_back(group.cell);
    group.count -= retire_count;
    const int64_t owner_capacity = saturating_mul(
        group.count, type.owner_slots_per_building, _saturation_count);
    group.filled_owner = std::min<int64_t>(group.filled_owner, owner_capacity);
    _building_handle_index_clean = false;
    if (group.count <= 0) {
        group.count = 0;
        group.merchant_debt_principal = 0;
        group.merchant_debt_premium = 0;
        group.merchant_debt_term_cycles_left = 0;
        group.merchant_debt_delinquent_cycles = 0;
        // A collapsed lot has no roles left. For a surviving lot, employee
        // seats continue describing the last completed employment period.
        for (int32_t role = 0; role < type.employee_count; ++role)
            _building_employee_filled.write_scalar(
                group.employee_fill_begin + role, 0, market_mutation_sink());
        ++_recovery_fully_liquidated_groups;
    } else {
        _recovery_partially_liquidated_buildings = saturating_add(
            _recovery_partially_liquidated_buildings,
            retire_count, _saturation_count);
    }
}

} // namespace pk
