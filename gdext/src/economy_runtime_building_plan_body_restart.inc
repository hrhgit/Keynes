        if (type.kind != 2 && group.operating_state == 1 && !suspended_now &&
            group.recovery_cooldown_cycles == 0) {
            ++_recovery_candidates;
            const int64_t building_days = saturating_mul(
                group.count, std::max(1, _epoch_days.get()), _saturation_count);
            // Optional inputs only add to base productivity. Empty tool
            // shelves must still allow a profitable, executable restart.
            bool physical_inputs_available = true;
            int64_t soft_bonus_sum_q16 = 0;
            int64_t restart_input_unit_cost = 0;
            int64_t restart_hard_input_unit_cost = 0;
            for (int32_t i = 0; i < type.input_count && physical_inputs_available; ++i) {
                const ProductionInput &item = _building_inputs[type.input_begin + i];
                const int64_t required_q16 = std::clamp<int64_t>(
                    item.required_q16, 0, Q16_ONE);
                if (required_q16 <= 0) continue;
                const int64_t effective = saturating_mul(
                    building_days, item.quantity, _saturation_count);
                bool candidate_available = false;
                int64_t best_unit_cost = std::numeric_limits<int64_t>::max();
                for (int32_t c = item.candidate_begin;
                     c < item.candidate_begin + item.candidate_count; ++c) {
                    const InputCandidate &candidate = _building_input_candidates[c];
                    if (!good_input_candidate_available(group.cell, candidate.good_id, true)) continue;
                    int64_t physical = mul_div_sat(effective, Q16_ONE,
                        std::max<int32_t>(1, candidate.efficiency_q16),
                        _saturation_count);
                    if (mul_div_sat(physical, candidate.efficiency_q16,
                            Q16_ONE, _saturation_count) < effective)
                        physical = saturating_add(physical, 1, _saturation_count);
                    physical = effective_production_input_quantity(
                        group.cell, candidate.good_id, physical,
                        _saturation_count, group.output_factor_q16);
                    const int64_t physical_numerator = saturating_add(
                        saturating_mul(item.quantity, Q16_ONE, _saturation_count),
                        candidate.efficiency_q16 - 1, _saturation_count);
                    const int64_t unit_physical = effective_production_input_quantity(
                        group.cell, candidate.good_id,
                        physical_numerator / std::max<int32_t>(1, candidate.efficiency_q16),
                        _saturation_count, group.output_factor_q16);
                    const int64_t candidate_cost = mul_div_sat(
                        unit_physical,
                        market_store().price[market_store().index(market, candidate.good_id)],
                        GOODS_SCALE, _saturation_count);
                    if (market_store().stock[market_store().index(market, candidate.good_id)] >= physical) {
                        candidate_available = true;
                        best_unit_cost = std::min(best_unit_cost, candidate_cost);
                    }
                }
                if (required_q16 >= Q16_ONE) {
                    physical_inputs_available = candidate_available;
                    if (candidate_available &&
                        best_unit_cost != std::numeric_limits<int64_t>::max()) {
                        restart_input_unit_cost = saturating_add(
                            restart_input_unit_cost, best_unit_cost,
                            _saturation_count);
                        restart_hard_input_unit_cost = saturating_add(
                            restart_hard_input_unit_cost, best_unit_cost,
                            _saturation_count);
                    }
                } else if (candidate_available &&
                    best_unit_cost != std::numeric_limits<int64_t>::max()) {
                    // Soft and stocked: include cost & capped bonus only if profitable.
                    const int64_t marginal_bonus_q16 =
                        soft_input_marginal_bonus_q16(type, required_q16);
                    const int64_t marginal_revenue = mul_div_sat(
                        revenue, marginal_bonus_q16,
                        Q16_ONE, _saturation_count);
                    if (marginal_revenue > best_unit_cost) {
                        restart_input_unit_cost = saturating_add(
                            restart_input_unit_cost, best_unit_cost,
                            _saturation_count);
                        soft_bonus_sum_q16 = saturating_add(
                            soft_bonus_sum_q16, marginal_bonus_q16,
                            _saturation_count);
                    }
                }
            }
            const int64_t soft_coverage_scale_q16 =
                clamp_soft_productivity_bonus_q16(soft_bonus_sum_q16);
            // Production clamps a resource-limited group to its capacity or
            // safe-harvest budget, so restart needs one building's worth, not
            // the whole group: 35 hunting camps built in a good decade need
            // far more than the regrown game's safe harvest and would
            // otherwise stay shut forever while the cell starves of protein.
            bool physical_resources_available = true;
            if (type.behavior_id == 1 || type.behavior_id == 2) {
                for (int32_t i = 0; i < type.resource_count; ++i) {
                    const ResourceAmount &item = _building_resources[type.resource_begin + i];
                    const int64_t raw_base = item.mode == 1
                        ? item.quantity
                        : saturating_mul(std::max(1, _epoch_days.get()),
                            item.quantity, _saturation_count);
                    const int64_t base = effective_resource_use_quantity(
                        group.cell, item.resource_id, raw_base, _saturation_count);
                    if (base > available_resource_amount(item, group.cell)) {
                        physical_resources_available = false;
                        break;
                    }
                }
            }
            const bool physical_requirements_met =
                physical_inputs_available && physical_resources_available;
            // Counterfactual restart margin must match the executable soft path:
            // unstocked soft inputs cut throughput and drop out of operating cost.
            int64_t recovery_profit_margin = expected_profit_margin;
            int64_t recovery_margin_denominator = std::max<int64_t>(
                MONEY_SCALE, operating);
            if (soft_coverage_scale_q16 != Q16_ONE ||
                restart_input_unit_cost != input_cost) {
                const int64_t recovery_revenue = mul_div_sat(
                    revenue, soft_coverage_scale_q16, Q16_ONE, _saturation_count);
                const int64_t recovery_operating = saturating_add(
                    saturating_add(saturating_add(restart_input_unit_cost,
                        employee_wages, _saturation_count),
                        owner_living_cost, _saturation_count),
                    maintenance_cost, _saturation_count);
                recovery_margin_denominator = std::max<int64_t>(
                    MONEY_SCALE, recovery_operating);
                const int64_t recovery_business_eligible = saturating_add(
                    saturating_add(restart_input_unit_cost, employee_wages,
                        _saturation_count),
                    maintenance_cost, _saturation_count);
                const int64_t recovery_business_base = expected_business_rate < 0
                    ? recovery_business_eligible
                    : std::max<int64_t>(0, recovery_revenue);
                const int64_t recovery_business_transfer =
                    expected_resolved_fiscal_transfer(
                        group.cell, CountryApi::TAX_BUSINESS,
                        group.type_id, recovery_business_base, 1,
                        _saturation_count);
                const int64_t recovery_income_base = std::max<int64_t>(0,
                    saturating_sub(saturating_sub(
                        recovery_revenue, recovery_business_eligible,
                        _saturation_count),
                        std::max<int64_t>(0, recovery_business_transfer),
                        _saturation_count));
                const int64_t recovery_income_transfer =
                    expected_resolved_fiscal_transfer(
                        group.cell, CountryApi::TAX_INCOME,
                        type.owner_profession_id,
                        expected_income_rate < 0
                            ? std::max<int64_t>(
                                recovery_income_base, owner_living_cost)
                            : recovery_income_base,
                        1, _saturation_count);
                const int64_t recovery_after_tax = saturating_sub(
                    saturating_sub(saturating_sub(recovery_revenue,
                        recovery_operating, _saturation_count),
                        recovery_business_transfer, _saturation_count),
                    recovery_income_transfer, _saturation_count);
                recovery_profit_margin = recovery_operating <= 0
                    ? (recovery_after_tax > 0 ? Q16_ONE : 0)
                    : mul_div_sat(recovery_after_tax, Q16_ONE,
                        std::max<int64_t>(MONEY_SCALE, recovery_operating),
                        _saturation_count);
                recovery_profit_margin = std::clamp<int64_t>(
                    recovery_profit_margin, -Q16_ONE, Q16_ONE);
            }
            // Owner-retained output is income for every building, including a
            // suspended one. Revalue it at the current market price in the
            // same recovery decision; do not create a food-only exception.
            if (physical_requirements_met) {
                int64_t quote_sat = 0;
                EconomyCostProbe::record("owner_quote.call.plan_recovery",
                                          _current_day.get(), 0.0, 1);
                const OwnerOpportunityQuote recovery_quote =
                    owner_opportunity_quote(group, Q16_ONE, Q16_ONE, quote_sat);
                const int64_t recovery_cash_profit = mul_div_sat(
                    recovery_profit_margin, recovery_margin_denominator,
                    Q16_ONE, _saturation_count);
                const int64_t recovery_total_profit = saturating_add(
                    recovery_cash_profit,
                    std::max<int64_t>(0, recovery_quote.in_kind_retail_value),
                    _saturation_count);
                recovery_profit_margin = std::clamp<int64_t>(mul_div_sat(
                    recovery_total_profit, Q16_ONE,
                    recovery_margin_denominator, _saturation_count),
                    -Q16_ONE, Q16_ONE);
                _saturation_count = saturating_add(_saturation_count, quote_sat,
                    _saturation_count);
            }
            const bool offer_jobs = physical_requirements_met &&
                recovery_profit_margin >= _building_restart_margin_q16.get();
            if (offer_jobs) {
                // Employment decides who takes the openings and whether
                // the vacancy streak ends. The normal production path
                // settles any purchases against actual balances.
                group.operating_state = 0;
                group.pending_operating_state = 255;
                _building_review_owner_vacancy[group_index] = 1;
                invalidate_cell_monetary_units(group.cell);
                ++_recovery_approved;
            } else {
                const bool vacancy_expired = group.filled_owner < group.count &&
                    group.severe_loss_cycles >= _building_severe_loss_cycles.get();
                // Preserve the review of executable but unprofitable lots.
                bool finance_available = false;
                if (physical_requirements_met && !vacancy_expired) {
                    const int32_t owner_slot = find_cohort_slot(
                        group.cell, group.owner_signature_id);
                    const int64_t owner_cash = owner_slot >= 0
                        ? std::max<int64_t>(0, population_store().funds[owner_slot]) : 0;
                    const int64_t restart_cost = saturating_add(
                        saturating_mul(restart_hard_input_unit_cost, building_days,
                            _saturation_count),
                        saturating_mul(employee_wages, building_days, _saturation_count),
                        _saturation_count);
                    const int64_t credit_needed = restart_cost -
                        std::min(restart_cost, owner_cash);
                    finance_available = credit_needed == 0 ||
                        (_merchant_credit_runtime_mode.get() != 0 &&
                         group.merchant_debt_delinquent_cycles == 0 &&
                         credit_needed <= cell_credit_remaining);
                }
                _building_recovery_liquidation_eligible[group_index] =
                    vacancy_expired || finance_available;
            }
        }
