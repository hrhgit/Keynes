#include "economy_runtime.h"

#include <algorithm>
#include <limits>
#include <tuple>

namespace pk {

// Different recipe edges can draw from the same shelf. Giving each edge its
// own copy bounds every possible prefix, including those changed by an earlier
// project's choice of substitutes. Prices are sorted before invoice rounding.
int64_t NativeEconomyRuntime::construction_material_capacity(
        int32_t market, int32_t type_id, int32_t factor, const std::vector<int64_t> &stock,
        int64_t ceiling, int64_t funding) const {
    struct Offer { int64_t whole, fraction, lots, quantity, price; };
    const auto &type = _building_types[type_id];
    if (ceiling <= 0 || type.construction_count == 0) return ceiling;
    std::vector<std::vector<Offer>> edges(type.construction_count);
    int64_t sat = 0;
    for (int i = 0; i < type.construction_count; ++i) {
        const auto edge = type.construction_begin + i;
        const int64_t required = construction_material_required(
            _building_construction_goods[edge].quantity, factor, sat);
        int64_t available = 0;
        for (int c = _building_construction_candidate_offsets[edge];
                c < _building_construction_candidate_offsets[edge + 1]; ++c) {
            const auto &candidate = _building_construction_candidates[c];
            const auto good = candidate.good_id;
            if (good < 0 || static_cast<size_t>(good) >= stock.size()) continue;
            const auto physical = construction_material_physical(required, candidate.efficiency_q16, sat);
            if (sat || physical <= 0) return ceiling;
            const auto lots = stock[good] / physical;
            if (lots == 0) continue;
            const int64_t price = market_store().price[market_store().index(market, good)];
            const auto whole = mul_div_sat(physical, price, GOODS_SCALE, sat);
            if (sat) return ceiling;
            const auto fraction = (physical % GOODS_SCALE) * (price % GOODS_SCALE) % GOODS_SCALE;
            edges[i].push_back({whole, fraction, lots, physical, price});
            available += std::min(ceiling - available, lots);
        }
        ceiling = std::min(ceiling, available);
        if (ceiling == 0) return 0;
        std::sort(edges[i].begin(), edges[i].end(), [](const Offer &a, const Offer &b) {
            return std::tie(a.whole, a.fraction) < std::tie(b.whole, b.fraction);
        });
    }
    // The cheapest aggregate invoice has nondecreasing marginal costs.
    auto affordable = [&](int64_t count) {
        GoodsBill invoice;
        for (const auto &edge : edges) {
            int64_t left = count;
            for (const auto &offer : edge) {
                const int64_t used = std::min(left, offer.lots);
                invoice.add(used * offer.quantity, offer.price, sat);
                left -= used;
                if (!left) break;
            }
        }
        const auto budget = saturating_mul(funding, count, sat);
        return sat != 0 || invoice.total(sat) <= budget;
    };
    int64_t lo = 0, hi = ceiling;
    while (lo < hi) {
        const auto mid = hi - (hi - lo) / 2;
        if (affordable(mid)) lo = mid;
        else hi = mid - 1;
    }
    return lo;
}

// Quote the original greedy recipe once per change of shelves. As stock only
// decreases, a chosen recipe repeats until one of its selected goods runs out.
// Return the largest funded prefix, including after a rounded-price tie.
int64_t NativeEconomyRuntime::quote_construction_lots(
        int32_t market, int32_t type_id, int32_t factor, std::vector<int64_t> &stock,
        int64_t count, int64_t funding, ConstructionMaterialPlan &plan, uint64_t *unit_quotes) const {
    const auto &type = _building_types[type_id];
    int64_t funded = 0, sat = 0;
    GoodsBill invoice;
    std::vector<GoodAmount> recipe;
    while (plan.quoted_count < count) {
        if (unit_quotes) ++*unit_quotes;
        recipe.clear();
        for (int i = 0; i < type.construction_count; ++i) {
            const int edge = type.construction_begin + i;
            const auto &preferred = _building_construction_goods[edge];
            const auto required = construction_material_required(preferred.quantity, factor, sat);
            int32_t good = -1;
            int64_t quantity = 0, cost = 0;
            for (int c = _building_construction_candidate_offsets[edge];
                    c < _building_construction_candidate_offsets[edge + 1]; ++c) {
                const auto &candidate = _building_construction_candidates[c];
                const auto id = candidate.good_id;
                if (id < 0 || static_cast<size_t>(id) >= stock.size()) continue;
                const auto physical = construction_material_physical(required, candidate.efficiency_q16, sat);
                if (stock[id] < physical) continue;
                const auto price = market_store().price[market_store().index(market, id)];
                const auto cash = goods_cost(physical, price, sat);
                if (good < 0 || std::make_tuple(cash, id != preferred.good_id, id) <
                        std::make_tuple(cost, good != preferred.good_id, good)) {
                    good = id;
                    cost = cash;
                    quantity = physical;
                }
            }
            if (good < 0) {
                plan.failed_group = i;
                return funded;
            }
            stock[good] -= quantity;
            const auto item = std::find_if(recipe.begin(), recipe.end(),
                [good](const GoodAmount &v) { return v.good_id == good; });
            if (item == recipe.end()) recipe.push_back({good, quantity});
            else item->quantity += quantity;
        }
        int64_t extra = count - plan.quoted_count - 1;
        for (const auto &item : recipe)
            extra = std::min(extra, stock[item.good_id] / item.quantity);
        const int64_t batch = 1 + extra;
        auto bill_after = [&](int64_t lots) {
            auto bill = invoice;
            for (const auto &item : recipe) {
                const auto price = market_store().price[market_store().index(market, item.good_id)];
                bill.add(lots * item.quantity, price, sat);
            }
            return bill;
        };
        const auto after = bill_after(batch);
        const int64_t done = plan.quoted_count;
        if (after.charged <= saturating_mul(done + batch, funding, sat)) {
            funded = done + batch;
        } else if (funded == done) {
            // Inside this run the exact cost is linear. Rounding the complete
            // bill preserves the comparison against an integer cash budget.
            int64_t lo = 0, hi = batch - 1;
            while (lo < hi) {
                const auto mid = hi - (hi - lo) / 2;
                if (bill_after(mid).charged <= saturating_mul(done + mid, funding, sat)) lo = mid;
                else hi = mid - 1;
            }
            funded = done + lo;
        }
        invoice = after;
        plan.total_cost = invoice.charged;
        for (const auto &item : recipe) {
            stock[item.good_id] -= extra * item.quantity;
            const auto pos = std::find(plan.good_ids.begin(), plan.good_ids.end(), item.good_id);
            if (pos == plan.good_ids.end()) {
                plan.good_ids.push_back(item.good_id);
                plan.quantities.push_back(batch * item.quantity);
            } else plan.quantities[pos - plan.good_ids.begin()] += batch * item.quantity;
        }
        plan.quoted_count += batch;
    }
    plan.feasible = true;
    return funded;
}

} // namespace pk
