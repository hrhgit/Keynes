#include "economy_invariant_probe.h"
#include "economy_runtime.h"
#include "country_api.h"

namespace pk {

bool EconomyInvariantProbe::run_frozen_tax_view(std::string &error) {
    auto economy = std::make_unique<NativeEconomyRuntime>();
    constexpr uint64_t resident = uint64_t{1} << 32;
    constexpr uint64_t landless = resident + 1;
    economy->_epoch_country_count = 2;
    economy->_epoch_country_handles = {resident, landless};
    economy->_epoch_cell_country = {0, 0, 0, 0, -1};
    economy->_profession_ids = {"p0", "p1"};
    economy->_good_ids = {"g0", "g1"};
    economy->_building_types.resize(2);
    economy->_epoch_income_tax_rates = {1001, 0, -45, 12};
    economy->_epoch_consumption_tax_rates = {100, 200, 0, 10};
    economy->_epoch_business_tax_rates = {300, -200, 0, 0};
    economy->_epoch_import_tax_rates = {500, 600, 0, 0};
    economy->_epoch_export_tax_rates = {700, 800, 0, 0};
    economy->_epoch_income_tax_modes = {0, 1, 0, 1};
    economy->_epoch_consumption_tax_modes = {0, 0, 0, 0};
    economy->_epoch_business_tax_modes = {1, 1, 0, 0};
    economy->_epoch_import_tax_modes = {0, 0, 0, 0};
    economy->_epoch_export_tax_modes = {0, 0, 0, 0};
    economy->_epoch_active_tax_mask = 31;
    economy->_epoch_has_cell_tax_policies = true;
    // Cell 1 shares the local policy but has no live economy and no active tax.
    economy->_epoch_cell_active_tax_mask = {31, 0, 31, 31, 0};
    economy->_epoch_cell_compiled_tax_policy = {0, 1, 1, 1, 0};
    economy->_epoch_compiled_cell_tax_policies.resize(2);
    auto &local = economy->_epoch_compiled_cell_tax_policies[1];
    local.override_end[0] = 1;
    local.default_row_ids[1] = 0;
    economy->_epoch_compiled_cell_tax_overrides = {{1, -727, 1}};
    economy->_epoch_compiled_cell_tax_default_rows = {{1, 0, 0, 0, 0, 2}};
    economy->_epoch_compiled_cell_tax_default_rates = {0, 127};
    economy->_epoch_compiled_cell_tax_default_modes = {0, 1};
    auto policy = std::make_shared<EconomyFrozenTaxView::PolicySnapshot>();
    policy->cell_country_slot = economy->_epoch_cell_country;
    economy->_epoch_tax_policy_version = 17;
    economy->publish_frozen_tax_view(9, policy);
    auto frame = economy->frozen_tax_view();
    int32_t rate = 0, mode = 0;
    if (!frame || frame->country != policy || frame->sample_day != 9 || frame->policy_version != 17) {
        error = "frozen_tax_frame_policy_or_date_mismatch";
        return false;
    }
    for (int32_t cell = -1; cell < 4; ++cell) {
        for (int32_t kind = 0; kind < CountryApi::TAX_KIND_COUNT; ++kind) {
            for (int32_t item = 0; item < 2; ++item) {
                const int32_t representative = cell < 0 ? 0 : cell;
                if (!frame->lookup(resident, cell, kind, item, rate, mode) ||
                    rate != economy->frozen_tax_rate(representative, kind, item) ||
                    mode != economy->frozen_tax_mode(representative, kind, item)) {
                    error = "frozen_tax_frame_settlement_mismatch";
                    return false;
                }
            }
        }
    }
    if (!frame->lookup(landless, -1, 0, 0, rate, mode) || rate != -45 || mode != 0 ||
        frame->lookup(0, -1, 0, 0, rate, mode) || frame->lookup(resident << 1, 0, 0, 0, rate, mode) ||
        frame->lookup(landless, 0, 0, 0, rate, mode) || frame->lookup(resident, 4, 0, 0, rate, mode) ||
        frame->lookup(resident, 5, 0, 0, rate, mode) || frame->lookup(resident, -2, 0, 0, rate, mode) ||
        frame->lookup(resident, 0, -1, 0, rate, mode) || frame->lookup(resident, 0, 5, 0, rate, mode) ||
        frame->lookup(resident, 0, 0, -1, rate, mode) || frame->lookup(resident, 0, 0, 2, rate, mode) ||
        rate != -45 || mode != 0) {
        error = "frozen_tax_frame_handle_or_range";
        return false;
    }
    economy->_epoch_income_tax_rates[0] = 2001;
    economy->publish_frozen_tax_view(10, policy);
    auto next = economy->frozen_tax_view();
    if (!next->lookup(resident, -1, 0, 0, rate, mode) || rate != 2001 ||
        !frame->lookup(resident, -1, 0, 0, rate, mode) || rate != 1001) {
        error = "frozen_tax_frame_changed_after_next_freeze";
        return false;
    }
    return true;
}

} // namespace pk
