    // Retain a legal ordinary allocation. When clipping or the final invoice
    // makes it infeasible, search the same ranked candidates in whole buildings.
    std::array<int64_t, 4> owner_slots{};
    for (int32_t i = 0; i < portfolio_size; ++i)
        owner_slots[i] = std::max<int64_t>(1,
            _building_types[portfolio[i].plan.type_id].owner_slots_per_building);
    int64_t search_saturation = 0;
    auto share_fits = [&]() {
        int64_t total = 0;
        int64_t largest = 0;
        for (int32_t i = 0; i < portfolio_size; ++i) {
            const int64_t seats = saturating_mul(owner_slots[i],
                portfolio[i].plan.allocated_count, search_saturation);
            total = saturating_add(total, seats, search_saturation);
            largest = std::max(largest, seats);
        }
        return largest <= mul_div_sat(total, share, Q16_ONE, search_saturation);
    };
    active_types = static_cast<int32_t>(std::count_if(portfolio.begin(), end, allocated));
    if ((portfolio_size == 1 && active_types == 1) || (active_types >= 2 && share_fits())) {
        if (quote_investment_portfolio(ctx, &ctx.rejected_invoice)) return;
        if (ctx.rejected_invoice >= 0)
            ctx.rejected_invoice_count = portfolio[ctx.rejected_invoice].plan.allocated_count;
        ++_building_investment_capital_limited;
    }

    // Retain the ordinary single-project size if no mixed combination works.
    if (active_types != 0) {
        for (int32_t i = 0; i < portfolio_size; ++i)
            proposal[i] = portfolio[i].plan.allocated_count;
    }
    active_types = 0;
    for (auto &candidate : portfolio) candidate.plan.allocated_count = 0;
    std::array<std::vector<int64_t>, 5> stock_by_depth;
    auto &opening_stock = stock_by_depth[0];
    opening_stock.resize(_good_ids.size());
    for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
        opening_stock[good] = std::max<int64_t>(0,
            market_store().stock[market_store().index(ctx.market, good)]);
    }
    const auto material_cap = [&](int32_t i, const auto &stock, int64_t cap) {
        return construction_material_capacity(
            portfolio[i].plan.type_id, investment_cost_factor, stock, cap);
    };
    auto &invoices = ctx.commit_material_plans;
    std::array<const InvestmentCandidatePlan *, 4> plans{};
    std::array<int64_t, 4> ceilings{};
    unsigned available = 0;
    for (int32_t i = 0; i < portfolio_size; ++i) {
        plans[i] = &portfolio[i].plan;
        invoices[i] = {};
        ceilings[i] = material_cap(i, opening_stock, additional_capacity(i, true));
        if (ceilings[i] > 0) available |= 1U << i;
    }
    // Each candidate is bounded by its funding, labour and the opening shelves.
    // In a branch, earlier invoices also consume stock before later types try
    // their counts. Use commit order so a prefix has exactly its final invoice.
    for (unsigned support = 1; support <= available; ++support) {
        if ((support & available) != support || (support & (support - 1)) == 0) continue;
        int32_t types = 0;
        for (unsigned bits = support; bits != 0; bits &= bits - 1) ++types;
        if (types * share < Q16_ONE) continue;
        auto find_counts = [&](auto &search, int32_t i, int64_t assigned,
                               int64_t largest, int32_t depth) -> bool {
            if (i == portfolio_size) {
                // A whole-cell cash replay can credit the seller of an earlier
                // invoice. Keep those incoming funds in the exact leaf check.
                return share_fits() && investment_portfolio_funds_feasible(
                    cell, plans.data(), invoices.data(), portfolio_size);
            }
            if ((support & (1U << i)) == 0)
                return search(search, i + 1, assigned, largest, depth);

            const auto &stock = stock_by_depth[depth];
            int64_t other_max = assigned;
            for (int32_t j = i + 1; j < portfolio_size; ++j) {
                if ((support & (1U << j)) == 0) continue;
                const int64_t future_limit = material_cap(j, stock, ceilings[j]);
                if (future_limit == 0) return false;
                other_max = saturating_add(other_max, saturating_mul(
                    future_limit, owner_slots[j], search_saturation), search_saturation);
            }
            int64_t limit = material_cap(i, stock,
                std::min(ceilings[i], additional_capacity(i, true)));
            if (share < Q16_ONE) {
                const int64_t allowed = mul_div_sat(other_max, share,
                    Q16_ONE - share, search_saturation);
                limit = std::min(limit, allowed / owner_slots[i]);
            }
            int64_t required_total = mul_div_sat(largest, Q16_ONE, share, search_saturation);
            if (mul_div_sat(required_total, share, Q16_ONE, search_saturation) < largest)
                required_total = saturating_add(required_total, 1, search_saturation);
            const int64_t required_seats = std::max<int64_t>(0, required_total - other_max);
            const int64_t minimum = std::max<int64_t>(1, required_seats / owner_slots[i] +
                (required_seats % owner_slots[i] != 0));
            for (int64_t count = minimum; count <= limit; ++count) {
                ++ctx.search_trials;
                auto &remaining_stock = stock_by_depth[depth + 1];
                remaining_stock = stock;
                if (!plan_construction_materials(cell, plans[i]->type_id, count,
                        investment_cost_factor, invoices[i], nullptr, &remaining_stock)) {
                    // The same greedy per-building prefix must fit at any larger count.
                    break;
                }
                int64_t invoice_saturation = 0;
                const int64_t funded_per_building = saturating_add(
                    plans[i]->funding_capital, plans[i]->merchant_credit, invoice_saturation);
                if (invoices[i].total_cost > saturating_mul(
                        count, funded_per_building, invoice_saturation) || invoice_saturation != 0) {
                    if (count == limit) break;
                    continue;
                }
                portfolio[i].plan.allocated_count = count;
                const int64_t seats = saturating_mul(count, owner_slots[i], search_saturation);
                if (search(search, i + 1,
                        saturating_add(assigned, seats, search_saturation),
                        std::max(largest, seats), depth + 1))
                    return true;
                // Do not leave this count installed for the next trial.
                portfolio[i].plan.allocated_count = 0;
                if (count == limit) break;
            }
            invoices[i] = {};
            return false;
        };
        if (find_counts(find_counts, 0, 0, 0, 0)) {
            active_types = types;
            return;
        }
    }

    for (int32_t i = 0; i < portfolio_size; ++i) {
        // Start with the ranked allocation. An excluded candidate can still
        // be a viable single project if the original allocation was unfunded.
        const int64_t original = std::min(proposal[i], ceilings[i]);
        const int64_t limit = original > 0 ? original
            : std::min(ceilings[i], additional_capacity(i));
        for (int64_t count = limit; count > 0; --count) {
            ++ctx.search_trials;
            portfolio[i].plan.allocated_count = count;
            if (quote_investment_portfolio(ctx)) {
                active_types = 1;
                return;
            }
        }
        portfolio[i].plan.allocated_count = 0;
    }
