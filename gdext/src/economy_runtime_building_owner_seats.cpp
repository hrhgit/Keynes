#include "economy_runtime.h"

#include <algorithm>
#include <map>

namespace pk {

int64_t NativeEconomyRuntime::building_owner_seats(BuildingGroupConstRef group, int32_t signature) const {
    int64_t registered = group.filled_owner;
    for (const auto &[owner, seats] : buildings_store().visiting_owners[group.index]) {
        if (owner == signature) return seats;
        registered -= seats;
    }
    return signature == group.owner_signature_id ? registered : 0;
}

void NativeEconomyRuntime::change_visiting_owner(size_t row, int32_t signature, int64_t change) {
    if (signature == building_view(row).owner_signature_id || change == 0) return;
    auto &owners = buildings_store().visiting_owners[row];
    const auto at = std::lower_bound(owners.begin(), owners.end(), signature,
        [](const auto &entry, int32_t id) { return entry.first < id; });
    if (at == owners.end() || at->first != signature) {
        if (change > 0) owners.emplace(at, signature, change);
    } else {
        at->second += change;
        if (at->second == 0) owners.erase(at);
    }
}

void NativeEconomyRuntime::limit_building_owner_fill(size_t row, int64_t limit) {
    auto group = building_at(row);
    if (group.filled_owner <= limit) return;
    auto &owners = buildings_store().visiting_owners[row];
    int64_t release = group.filled_owner - limit;
    // Keep registered seats first, then visiting seats in their stable order.
    while (release > 0 && !owners.empty()) {
        auto &seats = owners.back().second;
        const auto take = std::min(release, seats);
        release -= take;
        seats -= take;
        if (seats == 0) owners.pop_back();
    }
    group.filled_owner = limit;
}

// A removal or a population transfer may make seats unavailable. Consume each
// real cohort once, in the same opportunity order used by ordinary employment.
void NativeEconomyRuntime::retain_building_owners(int32_t cell, const std::vector<int32_t> &order,
        std::vector<int64_t> &retained) {
    retained.resize(_signatures.size());
    population_store().for_each_in_cell(cell, [&](int slot) {
        retained[population_store().signature_id[slot]] = 0;
    });
    auto keep = [&](int32_t sig, int64_t seats) -> int64_t {
        if (seats == 0) return 0;
        const int slot = population_store().find_signature(cell, sig);
        if (slot < 0) return 0;
        const int64_t available = population_store().population[slot] - retained[sig];
        const auto count = std::min(seats, std::max<int64_t>(0, available));
        retained[sig] += count;
        return count;
    };
    for (int row : order) {
        auto group = building_at(row);
        auto &owners = buildings_store().visiting_owners[row];
        int64_t registered = group.filled_owner;
        int64_t kept = 0;
        for (auto &[signature, seats] : owners) {
            registered -= seats;
            seats = keep(signature, seats);
            kept += seats;
        }
        owners.erase(std::remove_if(owners.begin(), owners.end(),
            [](const auto &entry) { return entry.second == 0; }), owners.end());
        group.filled_owner = kept + keep(group.owner_signature_id, registered);
    }
}

int32_t NativeEconomyRuntime::building_settlement_owner_slot(BuildingGroupConstRef group) const {
    // One invoice, loan and sales account per lot. Prefer a seated registered
    // owner; otherwise use the largest actual seat holding on this lot.
    int32_t signature = group.owner_signature_id;
    const auto &owners = buildings_store().visiting_owners[group.index];
    if (!owners.empty() && building_owner_seats(group, signature) == 0)
        signature = std::max_element(owners.begin(), owners.end(), [](const auto &a, const auto &b) {
            return a.second < b.second;
        })->first;
    return find_cohort_slot(group.cell, signature);
}

void NativeEconomyRuntime::migrate_building_owner_seats() {
    // Prior formats contain per-lot fill and per-cohort employment totals.
    // Reserve all matching registered seats before attributing any excess.
    std::map<std::pair<int32_t, int32_t>, int64_t> available;
    for (int cell : _building_active_cells) {
        population_store().for_each_in_cell(cell, [&](int slot) {
            if (population_store().owner_employed[slot] > 0)
                available[{cell, population_store().signature_id[slot]}] = population_store().owner_employed[slot];
        });
    }
    std::vector<int64_t> missing(building_count());
    for (size_t row = 0; row < building_count(); ++row) {
        const auto g = building_view(row);
        auto &local = available[{g.cell, g.owner_signature_id}];
        const auto keep = std::min<int64_t>(local, g.filled_owner);
        local -= keep;
        missing[row] = g.filled_owner - keep;
    }
    for (size_t row = 0; row < building_count(); ++row) {
        if (missing[row] == 0) continue;
        const auto g = building_view(row);
        const auto profession = _signatures[g.owner_signature_id].profession_id;
        for (auto it = available.lower_bound({g.cell, 0}); it != available.end() &&
                it->first.first == g.cell && missing[row] > 0; ++it) {
            const auto sig = it->first.second;
            if (sig == g.owner_signature_id || _signatures[sig].profession_id != profession) continue;
            const auto seats = std::min(it->second, missing[row]);
            change_visiting_owner(row, sig, seats);
            it->second -= seats;
            missing[row] -= seats;
        }
    }
}

} // namespace pk
