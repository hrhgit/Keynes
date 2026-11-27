#include "economy_runtime.h"
#include "country_api.h"

namespace pk {

bool EconomyFrozenTaxView::lookup(uint64_t handle, int32_t cell, int32_t kind, int32_t item,
                                  int32_t &rate, int32_t &mode) const {
    const size_t slot = static_cast<uint32_t>(handle);
    if (!country || handle == 0 || slot >= country_handles.size() || country_handles[slot] != handle ||
        kind < 0 || static_cast<size_t>(kind) >= KIND_COUNT ||
        item < 0 || static_cast<size_t>(item) >= item_counts[kind] || cell < -1)
        return false;
    if (cell >= 0 && (static_cast<size_t>(cell) >= country->cell_country_slot.size() ||
                      country->cell_country_slot[cell] != static_cast<int32_t>(slot)))
        return false;
    const size_t index = slot * item_counts[kind] + static_cast<size_t>(item);
    rate = national_rates[kind][index];
    mode = national_modes[kind][index];
    if (cell < 0) return true;
    const uint32_t policy = cell_policy[cell];
    if (policy != 0) {
        const auto &values = local_differences[policy][kind];
        const auto value = std::lower_bound(values.begin(), values.end(), item,
            [](const LocalValue &current, int32_t key) { return current.item < key; });
        if (value != values.end() && value->item == item) {
            rate = value->rate;
            mode = value->mode;
        }
    }
    return true;
}

void NativeEconomyRuntime::publish_frozen_tax_view(int64_t sample_day,
        std::shared_ptr<const EconomyFrozenTaxView::PolicySnapshot> country) {
    static_assert(CountryApi::TAX_KIND_COUNT == EconomyFrozenTaxView::KIND_COUNT);
    auto view = std::make_shared<EconomyFrozenTaxView>();
    view->country = std::move(country);
    view->sample_day = sample_day;
    view->policy_version = _epoch_tax_policy_version;
    view->country_handles.assign(_epoch_country_handles.begin(), _epoch_country_handles.end());
    view->item_counts = {_profession_ids.size(), _good_ids.size(), _building_types.size(),
                         _good_ids.size(), _good_ids.size()};
    view->national_rates = {_epoch_income_tax_rates, _epoch_consumption_tax_rates, _epoch_business_tax_rates,
                            _epoch_import_tax_rates, _epoch_export_tax_rates};
    view->national_modes = {_epoch_income_tax_modes, _epoch_consumption_tax_modes, _epoch_business_tax_modes,
                            _epoch_import_tax_modes, _epoch_export_tax_modes};
    view->cell_policy = _epoch_cell_compiled_tax_policy;
    view->local_differences.resize(_epoch_compiled_cell_tax_policies.size());

    // A compiled policy ID identifies a (country, local policy) pair. Read its
    // applicable values once per distinct row, whether that cell had taxpayers or not.
    std::vector<bool> captured(view->local_differences.size());
    for (size_t cell = 0; cell < view->cell_policy.size(); ++cell) {
        const uint32_t policy = view->cell_policy[cell];
        if (!policy || captured[policy]) continue;
        captured[policy] = true;
        const size_t slot = static_cast<size_t>(_epoch_cell_country[cell]);
        for (int32_t kind = 0; kind < CountryApi::TAX_KIND_COUNT; ++kind) {
            const size_t count = view->item_counts[kind];
            for (size_t item = 0; item < count; ++item) {
                const auto id = static_cast<int32_t>(item);
                const auto [rate, mode] = applicable_frozen_tax(static_cast<int32_t>(cell), kind, id);
                const size_t index = slot * count + item;
                if (rate != view->national_rates[kind][index] || mode != view->national_modes[kind][index])
                    view->local_differences[policy][kind].push_back({id, rate, mode});
            }
        }
    }
    std::atomic_store(&_frozen_tax_view, std::shared_ptr<const EconomyFrozenTaxView>(std::move(view)));
}

} // namespace pk
