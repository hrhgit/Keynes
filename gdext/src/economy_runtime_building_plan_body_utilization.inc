        if (group.operating_state != 1) {
            // A rational operator scales only against expected after-tax cash
            // profit. Demand, inventory, sell-through and shortages contribute
            // to the revenue forecast above, but are not independent priorities
            // or health gates. Physical input/resource capacity remains applied
            // below because it is an execution constraint, not a preference.
            const int64_t expected_operating_cost = saturating_add(
                saturating_add(input_cost, employee_wages, _saturation_count),
                saturating_add(owner_living_cost, maintenance_cost,
                    _saturation_count), _saturation_count);
            const int64_t expected_business_eligible_cost = saturating_add(
                saturating_add(input_cost, employee_wages, _saturation_count),
                maintenance_cost, _saturation_count);
            const int32_t business_rate = frozen_tax_rate(
                group.cell, CountryApi::TAX_BUSINESS, group.type_id);
            const int64_t business_base = business_rate < 0
                ? expected_business_eligible_cost : std::max<int64_t>(0, revenue);
            const int64_t business_transfer = expected_resolved_fiscal_transfer(
                group.cell, CountryApi::TAX_BUSINESS, group.type_id,
                business_base, 1, _saturation_count);
            const int64_t income_base = std::max<int64_t>(0,
                saturating_sub(saturating_sub(
                    revenue, expected_business_eligible_cost, _saturation_count),
                    std::max<int64_t>(0, business_transfer), _saturation_count));
            const int32_t income_rate = frozen_tax_rate(
                group.cell, CountryApi::TAX_INCOME,
                type.owner_profession_id);
            const int64_t income_transfer = expected_resolved_fiscal_transfer(
                group.cell, CountryApi::TAX_INCOME,
                type.owner_profession_id,
                income_rate < 0
                    ? std::max<int64_t>(income_base, owner_living_cost)
                    : income_base,
                1, _saturation_count);
            // Owner-retained output is economic income for every building.
            // Cache the current-price opportunity quote for this group during
            // the frozen epoch, rather than reusing last epoch's currency
            // value. A new epoch invalidates the cache and observes prices,
            // stocks, and demand again.
            thread_local const NativeEconomyRuntime *in_kind_cache_runtime = nullptr;
            thread_local int64_t in_kind_cache_epoch = std::numeric_limits<int64_t>::min();
            thread_local std::vector<int64_t> in_kind_cache_values;
            thread_local std::vector<uint8_t> in_kind_cache_valid;
            if (in_kind_cache_runtime != this || in_kind_cache_epoch != _epoch_id.get()) {
                in_kind_cache_runtime = this;
                in_kind_cache_epoch = _epoch_id.get();
                in_kind_cache_values.assign(building_count(), 0);
                in_kind_cache_valid.assign(building_count(), 0);
            } else if (in_kind_cache_values.size() < building_count()) {
                const size_t old_size = in_kind_cache_values.size();
                in_kind_cache_values.resize(building_count(), 0);
                in_kind_cache_valid.resize(building_count(), 0);
                std::fill(in_kind_cache_valid.begin() + old_size,
                    in_kind_cache_valid.end(), 0);
            }
            int64_t expected_in_kind = 0;
            if (group.index >= 0 && group.index < static_cast<int32_t>(
                    in_kind_cache_values.size())) {
                const size_t cache_index = static_cast<size_t>(group.index);
                if (in_kind_cache_valid[cache_index] == 0) {
                    EconomyCostProbe::record("owner_quote.call.plan_inkind",
                                              _current_day.get(), 0.0, 1);
                    const OwnerOpportunityQuote opportunity = owner_opportunity_quote(
                        group, Q16_ONE, Q16_ONE, _saturation_count);
                    in_kind_cache_values[cache_index] = std::max<int64_t>(0,
                        opportunity.in_kind_retail_value);
                    in_kind_cache_valid[cache_index] = 1;
                }
                expected_in_kind = in_kind_cache_values[cache_index];
            }
            const int64_t expected_cash_profit = saturating_sub(
                saturating_sub(saturating_sub(revenue, expected_operating_cost,
                    _saturation_count), business_transfer, _saturation_count),
                income_transfer, _saturation_count);
            // When an observed group uses its realized-receipt quote above,
            // retained owner output is already part of `revenue`.  Add the
            // counterfactual in-kind quote only for unobserved groups so the
            // unified income basis does not count the same livelihood twice.
            const int64_t expected_profit = saturating_add(
                expected_cash_profit,
                observed_capacity ? 0 : expected_in_kind,
                _saturation_count);
            // Pure self-employment (no employees) with positive net owner income
            // after operating costs and taxes keeps full planned utilization
            // instead of collapsing to the 3.1% probe floor on planning days
            // (matching positive_self_employment in the suspension gate above).
            const int64_t expected_owner_net_income = saturating_add(
                expected_profit, owner_living_cost, _saturation_count);
            const bool positive_planned_self_employment =
                type.employee_count == 0 && expected_owner_net_income > 0;
            group.planned_utilization_q16 =
                (expected_profit > 0 || positive_planned_self_employment)
                    ? static_cast<int32_t>(Q16_ONE) : 0;
            // Survival output is a bounded exception to pure cash-profit
            // gating. It may run only far enough to cover the frozen
            // subsistence/clothing floor computed for this owner, while its
            // monetary forecast remains the factual receipt above (possibly
            // zero). Resource, input, climate, and working-capital checks
            // below still constrain what can actually execute.
            if (group_index >= 0 && group_index < static_cast<int32_t>(
                    _building_survival_utilization_floor_q16.size())) {
                group.planned_utilization_q16 = std::max<int32_t>(
                    group.planned_utilization_q16,
                    static_cast<int32_t>(std::clamp<int64_t>(
                        _building_survival_utilization_floor_q16[group_index],
                        0, Q16_ONE)));
            }
            // Keep a bounded industrial probe for an occupied group even when
            // the current quote is temporarily unprofitable or input-funded
            // production is blocked. This preserves intent and the next
            // cycle's demand signal without creating a vacant owner or
            // bypassing physical input checks.
            if (group.filled_owner > 0 && type.input_count > 0 &&
                type.output_count > 0) {
                int32_t probe_floor_q16 = Q16_ONE / 32 + 1;
                for (int32_t i = 0; i < type.output_count; ++i) {
                    const int32_t output_good = _building_outputs[
                        type.output_begin + i].good_id;
                    if (output_good >= 0 && output_good <
                            static_cast<int32_t>(_good_storage_modes.size()) &&
                        _good_storage_modes[output_good] == 1) {
                        probe_floor_q16 = std::max<int32_t>(
                            probe_floor_q16, Q16_ONE / 6 + 1);
                    }
                }
                group.planned_utilization_q16 = std::max<int32_t>(
                    group.planned_utilization_q16, probe_floor_q16);
            }
        } else {
            group.planned_utilization_q16 = 0;
        }
        // Natural constraints are applied once by the production quote.  The
        // planning pass only decides whether the group wants to operate; it
        // must not pre-clamp the same plan by resource and climate again.
        // Otherwise owner/finance intent, resource capacity, and climate are
        // all counted as competing utilization minima before production even
        // gets a chance to form the final output quantity.
        if (group_index < static_cast<int32_t>(
                _building_planned_capacity_before_climate_q16.size())) {
            _building_planned_capacity_before_climate_q16[group_index] =
                group.planned_utilization_q16;
        }
        const int64_t effective_execution_q16 = std::min<int64_t>(
            std::clamp<int64_t>(actual_workforce_capacity_q16, 0, Q16_ONE),
            std::clamp<int64_t>(group.planned_utilization_q16, 0, Q16_ONE));
        group.purchase_intent_capacity_q16 = 0;
        const int64_t group_days = saturating_mul(
            group.count, std::max(1, _epoch_days.get()), _saturation_count);
        group.last_expected_revenue = mul_div_sat(
            saturating_mul(group_days, full_capacity_revenue, _saturation_count),
            effective_execution_q16, Q16_ONE, _saturation_count);
        group.last_quoted_market_receipt = group.last_expected_revenue;
        group.last_quoted_operating_cost = mul_div_sat(
            saturating_mul(group_days, operating, _saturation_count),
            effective_execution_q16, Q16_ONE, _saturation_count);
        group.last_maintenance_due = mul_div_sat(
            saturating_mul(group_days, maintenance_cost, _saturation_count),
            effective_execution_q16, Q16_ONE, _saturation_count);
        if (margin_gap < 0) ++_unprofitable_building_groups;
        if (group.operating_state != 0) ++_loss_suspended_building_groups;
        _utilization_sum_q16 = saturating_add(
            _utilization_sum_q16, group.planned_utilization_q16, _saturation_count);
