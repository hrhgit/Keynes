#include "economy_runtime_building_employment_includes.inc"

namespace pk {

bool NativeEconomyRuntime::profession_entry_savings_allows(
        int32_t cell, int32_t source_slot, int32_t source_profession,
        int32_t target_profession, int64_t &sat) const {
    // The entry gate measures per-capita savings in days of local living cost.
    // Moving from a profession with an equal or higher gate stays free.
    const auto entry_days = [&](int32_t profession) -> int64_t {
        return profession >= 0 && static_cast<size_t>(profession) <
            _profession_entry_savings_days.size()
            ? _profession_entry_savings_days[profession] : 0;
    };
    const int64_t required_days = entry_days(target_profession);
    if (required_days <= 0 || entry_days(source_profession) >= required_days)
        return true;
    if (source_slot < 0) return false;
    const int64_t living_cost = static_cast<size_t>(cell) < _cell_living_cost_per_capita.size()
        ? std::max<int64_t>(0, _cell_living_cost_per_capita[cell]) : 0;
    const int64_t people = std::max<int64_t>(1, population_store().population[source_slot]);
    const int64_t per_capita = std::max<int64_t>(0, population_store().funds[source_slot]) / people;
    return per_capita >= saturating_mul(living_cost, required_days, sat);
}

int64_t NativeEconomyRuntime::unemployed_disposable_income_at(
        int32_t cell, int32_t slot, int64_t &sat) const {
    if (static_cast<size_t>(slot) >= population_store().population.size()) return 0;
    const uint32_t signature = population_store().signature_id[slot];
    if (signature >= _signatures.size()) return 0;
    const int32_t profession = _signatures[signature].profession_id;
    if (profession != _unemployed_profession_id) return 0;
    // A funded negative income tax is reservation income. Carried savings
    // and attribution from a previous job are not current income.
    if (frozen_tax_rate(cell, CountryApi::TAX_INCOME, profession) >= 0) return 0;
    const int64_t daily_floor = living_cost_for_signature(
        cell, signature, _living_cost_base_plan_id, sat);
    const int64_t signed_transfer = expected_resolved_fiscal_transfer(
        cell, CountryApi::TAX_INCOME, profession, daily_floor, 1, sat);
    const int64_t funded_transfer = std::max<int64_t>(0, saturating_sub(0, signed_transfer, sat));
    const size_t lane = static_cast<size_t>(cell) * ACTIVE_TAX_KIND_COUNT +
        CountryApi::TAX_INCOME;
    const int32_t fulfillment = lane < _fiscal_fulfillment_q16.size()
        ? std::clamp<int32_t>(_fiscal_fulfillment_q16[lane], 0, Q16_ONE) : 0;
    const int64_t funded_period_floor = mul_div_sat(
        saturating_mul(daily_floor, std::max<int64_t>(1, _epoch_days.get()), sat),
        fulfillment, Q16_ONE, sat);
    return std::max(funded_transfer, funded_period_floor);
}

NativeEconomyRuntime::EmploymentRejection
NativeEconomyRuntime::unemployed_owner_hire_rejection(
        int32_t cell, int32_t source_slot, int32_t target_profession,
        int64_t source_disposable, int64_t target_disposable, int64_t &sat) const {
    if (source_slot < 0) return EMPLOYMENT_REJECTION_POOL_MISSING;
    if (population_store().population[source_slot] <= 0) return EMPLOYMENT_REJECTION_POOL_EMPTY;
    const uint32_t source_id = population_store().signature_id[source_slot];
    if (source_id >= _signatures.size() ||
            _signatures[source_id].profession_id != _unemployed_profession_id)
        return EMPLOYMENT_REJECTION_SOURCE_SIGNATURE;
    const int32_t target_id = signature_for_profession_ethnicity(
        target_profession, _signatures[source_id].ethnicity_id);
    if (target_id < 0) return EMPLOYMENT_REJECTION_TARGET_SIGNATURE;
    if (static_cast<uint32_t>(target_id) == source_id) return EMPLOYMENT_REJECTION_SIGNATURE_SELF;
    if (profession_is_state_service_only(target_profession))
        return EMPLOYMENT_REJECTION_PROFESSION_UNAVAILABLE;
    if (!profession_entry_savings_allows(cell, source_slot, _unemployed_profession_id,
                                        target_profession, sat))
        return EMPLOYMENT_REJECTION_ENTRY_SAVINGS;
    if (_employment_mobility_daily_q16.get() <= 0)
        return EMPLOYMENT_REJECTION_NO_ALLOCATION;
    if (target_disposable < 0) return EMPLOYMENT_REJECTION_TARGET_DISPOSABLE;
    // The hurdle from unemployment is zero, subject to reservation income.
    if (target_disposable < source_disposable) return EMPLOYMENT_REJECTION_HURDLE;
    return EMPLOYMENT_REJECTION_NONE;
}

int64_t NativeEconomyRuntime::owner_mobility_income_per_day(
        BuildingGroupConstRef group, int64_t &sat) const {
    if (group.type_id < 0 || static_cast<size_t>(group.type_id) >= _building_types.size() ||
            group.count <= 0) return 0;
    if (group.operating_state != 0) return 0;
    const bool has_settled = group.last_output > 0 || group.last_sold > 0 ||
        group.last_market_receipt > 0 || group.last_in_kind_livelihood_value > 0 ||
        group.last_input_cost > 0 || group.last_base_wages_paid > 0;
    // Active owners compare settled returns, using a counterfactual income
    // only when the lot has not yet settled.
    if (has_settled)
        return projected_owner_income_per_day(group, sat);
    int64_t quote_sat = 0;
    EconomyCostProbe::record("owner_quote.call.emp_settle_gate", _current_day.get(), 0.0, 1);
    const OwnerOpportunityQuote quote = owner_opportunity_quote(group, Q16_ONE, Q16_ONE, quote_sat);
    sat = saturating_add(sat, quote_sat, sat);
    if (!quote.feasible || quote.executable_capacity_q16 <= 0) return 0;
    return std::max<int64_t>(0, quote.disposable_survival_power_per_day);
}

} // namespace pk
