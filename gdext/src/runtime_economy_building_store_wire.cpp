#include "runtime_economy_building_store.h"
#include "economy_wire_sink.h"

#include <algorithm>
#include <cstring>

namespace pk {
namespace {

constexpr uint64_t kFnvOffset = 1469598103934665603ull;
constexpr uint64_t kFnvPrime = 1099511628211ull;

template <typename Sink, typename T>
void append_pod(Sink &out, const T &value) {
    economy_wire_append(out, value);
}

template <typename T>
bool read_pod(const uint8_t *&p, const uint8_t *end, T &value) {
    if (static_cast<size_t>(end - p) < sizeof(T)) return false;
    std::memcpy(&value, p, sizeof(T));
    p += sizeof(T);
    return true;
}

} // namespace
namespace {
constexpr uint32_t kBuildingVacancyWireVersion = 1;
constexpr uint32_t kBuildingOwnerWireVersion = 2;
}

template <typename Sink>
void RuntimeEconomyBuildingStore::visit_wire(Sink &out) const {
    const size_t groups = cell.size();
    for (size_t g = 0; g < groups; ++g) {
        append_pod(out, cell[g]);
        append_pod(out, type_id[g]);
        append_pod(out, owner_signature_id[g]);
        append_pod(out, group_units[g]);
        append_pod(out, filled_owner[g]);
        append_pod(out, last_capacity_q16[g]);
        append_pod(out, last_temperature_fit_q16[g]);
        append_pod(out, last_water_fit_q16[g]);
        append_pod(out, last_climate_capacity_q16[g]);
        append_pod(out, last_climate_lost_output[g]);
        append_pod(out, last_input[g]);
        append_pod(out, last_output[g]);
        append_pod(out, last_sold[g]);
        append_pod(out, last_discarded[g]);
        append_pod(out, last_resource[g]);
        append_pod(out, last_resource_generated[g]);
        append_pod(out, last_revenue[g]);
        append_pod(out, last_input_cost[g]);
        append_pod(out, last_wages_paid[g]);
        append_pod(out, last_wages_due[g]);
        append_pod(out, last_expected_revenue[g]);
        append_pod(out, last_operating_cost[g]);
        append_pod(out, last_margin_gap_q16[g]);
        append_pod(out, planned_utilization_q16[g]);
        append_pod(out, last_base_wages_paid[g]);
        append_pod(out, last_base_wages_due[g]);
        append_pod(out, last_bonus_paid[g]);
        append_pod(out, last_bonus_due[g]);
        append_pod(out, wage_suspended[g]);
        append_pod(out, purchase_intent_capacity_q16[g]);
        append_pod(out, realized_profit_margin_q16[g]);
        append_pod(out, severe_loss_cycles[g]);
        append_pod(out, recovery_cycles[g]);
        append_pod(out, operating_state[g]);
        append_pod(out, pending_operating_state[g]);
        append_pod(out, recovery_cooldown_cycles[g]);
        append_pod(out, recovery_failed_reviews[g]);
        append_pod(out, merchant_debt_term_cycles_left[g]);
        append_pod(out, merchant_debt_delinquent_cycles[g]);
        append_pod(out, merchant_debt_principal[g]);
        append_pod(out, merchant_debt_premium[g]);
        append_pod(out, last_in_kind_livelihood_value[g]);
        append_pod(out, last_market_receipt[g]);
        append_pod(out, last_bullion_mint_receipt[g]);
        append_pod(out, last_producer_support_receipt[g]);
        append_pod(out, last_business_tax_paid[g]);
        append_pod(out, last_business_subsidy_received[g]);
        append_pod(out, last_maintenance_due[g]);
        append_pod(out, last_observed_capacity_days_q16[g]);
        append_pod(out, last_quoted_market_receipt[g]);
        append_pod(out, last_quoted_operating_cost[g]);
        append_pod(out, role_count[g]);
        const int32_t begin = role_begin[g];
        const int32_t roles = role_count[g];
        for (int32_t r = 0; r < roles; ++r) {
            const size_t index = static_cast<size_t>(begin + r);
            append_pod(out, role_filled[index]);
            append_pod(out, role_contract_wage[index]);
            append_pod(out, role_base_living_cost[index]);
            append_pod(out, role_living_cost[index]);
            append_pod(out, role_local_average_wage[index]);
            append_pod(out, role_base_wage_due[index]);
            append_pod(out, role_base_wage_paid[index]);
            append_pod(out, role_bonus_due[index]);
            append_pod(out, role_bonus_paid[index]);
        }
    }
    const size_t pending = pending_cell.size();
    for (size_t i = 0; i < pending; ++i) {
        append_pod(out, pending_cell[i]);
        append_pod(out, pending_type_id[i]);
        append_pod(out, pending_owner_signature_id[i]);
        append_pod(out, pending_count[i]);
        append_pod(out, pending_ready_day[i]);
        append_pod(out, pending_sequence[i]);
        append_pod(out, pending_merchant_debt_principal[i]);
        append_pod(out, pending_merchant_debt_premium[i]);
        append_pod(out, pending_merchant_debt_term_cycles_left[i]);
        append_pod(out, pending_sponsor_family_handle[i]);
    }
    // Optional versioned trailer. Its absence carries no vacancy evidence.
    const bool has_owners = std::any_of(visiting_owners.begin(), visiting_owners.end(),
        [](const auto &seats) { return !seats.empty(); });
    if (has_owners || std::any_of(owner_vacancy_cycles.begin(), owner_vacancy_cycles.end(),
            [](uint16_t cycles) { return cycles != 0; })) {
        append_pod(out, has_owners ? kBuildingOwnerWireVersion : kBuildingVacancyWireVersion);
        for (size_t g = 0; g < groups; ++g) {
            append_pod(out, owner_vacancy_cycles[g]);
            append_pod(out, vacant_buildings[g]);
        }
        if (has_owners) {
            for (const auto &owners : visiting_owners) {
                append_pod(out, static_cast<uint32_t>(owners.size()));
                for (const auto &[signature, seats] : owners) {
                    append_pod(out, signature);
                    append_pod(out, seats);
                }
            }
        }
    }
}

bool RuntimeEconomyBuildingStore::load_wire(
        const uint8_t *data, size_t size, uint32_t expected_groups,
        uint32_t expected_pending, uint32_t expected_roles) {
    clear();
    if (data == nullptr && size != 0) return false;
    const uint8_t *p = data;
    const uint8_t *end = data + size;
    cell.reserve(expected_groups);
    role_filled.reserve(expected_roles);
    pending_cell.reserve(expected_pending);
    for (uint32_t g = 0; g < expected_groups; ++g) {
        int32_t v_i32 = 0;
        int64_t v_i64 = 0;
        uint8_t v_u8 = 0;
        uint16_t v_u16 = 0;
        auto push_i32 = [&](EconomyTrackedColumn<int32_t> &dst) -> bool {
            if (!read_pod(p, end, v_i32)) return false;
            dst.push_back(v_i32);
            return true;
        };
        auto push_i64 = [&](EconomyTrackedColumn<int64_t> &dst) -> bool {
            if (!read_pod(p, end, v_i64)) return false;
            dst.push_back(v_i64);
            return true;
        };
        auto push_u8 = [&](EconomyTrackedColumn<uint8_t> &dst) -> bool {
            if (!read_pod(p, end, v_u8)) return false;
            dst.push_back(v_u8);
            return true;
        };
        auto push_u16 = [&](EconomyTrackedColumn<uint16_t> &dst) -> bool {
            if (!read_pod(p, end, v_u16)) return false;
            dst.push_back(v_u16);
            return true;
        };
        if (!push_i32(cell) || !push_i32(type_id) ||
            !push_i32(owner_signature_id) || !push_i64(group_units) ||
            !push_i64(filled_owner) || !push_i64(last_capacity_q16) ||
            !push_i64(last_temperature_fit_q16) ||
            !push_i64(last_water_fit_q16) ||
            !push_i64(last_climate_capacity_q16) ||
            !push_i64(last_climate_lost_output) || !push_i64(last_input) ||
            !push_i64(last_output) || !push_i64(last_sold) ||
            !push_i64(last_discarded) || !push_i64(last_resource) ||
            !push_i64(last_resource_generated) || !push_i64(last_revenue) ||
            !push_i64(last_input_cost) || !push_i64(last_wages_paid) ||
            !push_i64(last_wages_due) || !push_i64(last_expected_revenue) ||
            !push_i64(last_operating_cost) || !push_i32(last_margin_gap_q16) ||
            !push_i32(planned_utilization_q16) ||
            !push_i64(last_base_wages_paid) || !push_i64(last_base_wages_due) ||
            !push_i64(last_bonus_paid) || !push_i64(last_bonus_due) ||
            !push_u8(wage_suspended) ||
            !push_i64(purchase_intent_capacity_q16) ||
            !push_i32(realized_profit_margin_q16) ||
            !push_u16(severe_loss_cycles) || !push_u16(recovery_cycles) ||
            !push_u8(operating_state) || !push_u8(pending_operating_state) ||
            !push_u16(recovery_cooldown_cycles) ||
            !push_u16(recovery_failed_reviews) ||
            !push_u16(merchant_debt_term_cycles_left) ||
            !push_u16(merchant_debt_delinquent_cycles) ||
            !push_i64(merchant_debt_principal) ||
            !push_i64(merchant_debt_premium) ||
            !push_i64(last_in_kind_livelihood_value) ||
            !push_i64(last_market_receipt) ||
            !push_i64(last_bullion_mint_receipt) ||
            !push_i64(last_producer_support_receipt) ||
            !push_i64(last_business_tax_paid) ||
            !push_i64(last_business_subsidy_received) ||
            !push_i64(last_maintenance_due) ||
            !push_i64(last_observed_capacity_days_q16) ||
            !push_i64(last_quoted_market_receipt) ||
            !push_i64(last_quoted_operating_cost)) {
            clear();
            return false;
        }
        int32_t roles = 0;
        if (!read_pod(p, end, roles) || roles < 0) {
            clear();
            return false;
        }
        role_count.push_back(roles);
        role_begin.push_back(static_cast<int32_t>(role_filled.size()));
        for (int32_t r = 0; r < roles; ++r) {
            if (!push_i64(role_filled) || !push_i64(role_contract_wage) ||
                !push_i64(role_base_living_cost) ||
                !push_i64(role_living_cost) ||
                !push_i64(role_local_average_wage) ||
                !push_i64(role_base_wage_due) ||
                !push_i64(role_base_wage_paid) || !push_i64(role_bonus_due) ||
                !push_i64(role_bonus_paid)) {
                clear();
                return false;
            }
        }
    }
    for (uint32_t i = 0; i < expected_pending; ++i) {
        int32_t v_i32 = 0;
        int64_t v_i64 = 0;
        uint16_t v_u16 = 0;
        uint64_t v_u64 = 0;
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        pending_cell.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        pending_type_id.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        pending_owner_signature_id.push_back(v_i32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        pending_count.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        pending_ready_day.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        pending_sequence.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        pending_merchant_debt_principal.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        pending_merchant_debt_premium.push_back(v_i64);
        if (!read_pod(p, end, v_u16)) {
            clear();
            return false;
        }
        pending_merchant_debt_term_cycles_left.push_back(v_u16);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        pending_sponsor_family_handle.push_back(v_u64);
    }
    visiting_owners.resize(expected_groups);
    if (p == end) {
        owner_vacancy_cycles.assign(expected_groups, 0);
        vacant_buildings.assign(expected_groups, 0);
    } else {
        uint32_t version = 0;
        if (!read_pod(p, end, version) || (version != kBuildingVacancyWireVersion && version != kBuildingOwnerWireVersion) ||
            static_cast<uint64_t>(expected_groups) * 10u > static_cast<size_t>(end - p)) {
            clear();
            return false;
        }
        for (uint32_t g = 0; g < expected_groups; ++g) {
            uint16_t cycles = 0;
            int64_t vacant = 0;
            if (!read_pod(p, end, cycles) || !read_pod(p, end, vacant) ||
                !valid_vacancy_history(group_units[g], cycles, vacant)) {
                clear();
                return false;
            }
            owner_vacancy_cycles.push_back(cycles);
            vacant_buildings.push_back(vacant);
        }
        if (version == kBuildingOwnerWireVersion) {
            for (uint32_t g = 0; g < expected_groups; ++g) {
                uint32_t count = 0;
                if (!read_pod(p, end, count) || count > static_cast<size_t>(end - p) / 12u) {
                    clear();
                    return false;
                }
                auto &owners = visiting_owners[g];
                int64_t remaining = filled_owner[g];
                for (uint32_t i = 0; i < count; ++i) {
                    int32_t sig = 0;
                    int64_t seats = 0;
                    if (!read_pod(p, end, sig) || !read_pod(p, end, seats) ||
                        sig < 0 || sig == owner_signature_id[g] || seats <= 0 || seats > remaining ||
                        (!owners.empty() && sig <= owners.back().first)) {
                        clear();
                        return false;
                    }
                    owners.emplace_back(sig, seats);
                    remaining -= seats;
                }
            }
        }
    }
    if (p != end) {
        clear();
        return false;
    }
    // ABI7 wire omits live-only AoS columns; default them after unpack.
    const size_t groups = cell.size();
    employee_fill_begin.assign(groups, -1);
    last_input_selection_begin.assign(groups, -1);
    last_maintenance_cost.assign(groups, 0);
    sample_unit_input_cost.assign(groups, 0);
    sample_unit_maintenance_cost.assign(groups, 0);
    modifier_handle.assign(groups, 0);
    output_factor_q16.assign(groups, 65536);
    return shape_valid(expected_groups, expected_pending, expected_roles);
}

void RuntimeEconomyBuildingStore::append_wire(std::vector<uint8_t> &out) const {
    visit_wire(out);
}

uint64_t RuntimeEconomyBuildingStore::wire_content_hash() const noexcept {
    EconomyWireHashSink sink{kFnvOffset};
    visit_wire(sink);
    return sink.hash;
}

uint64_t RuntimeEconomyBuildingStore::mix_wire_hash(uint64_t hash) const noexcept {
    EconomyWireSizeSink size;
    visit_wire(size);
    EconomyWireHashSink sink{(hash ^ static_cast<uint64_t>(size.size)) * kFnvPrime};
    visit_wire(sink);
    return sink.hash;
}

} // namespace pk
