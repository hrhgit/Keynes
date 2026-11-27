#include "modifier_runtime.h"
#include "modifier_value_query.h"

namespace pk {

bool ModifierRuntime::read_view_self_test(std::string &error) {
    const auto fail = [&](const char *reason) { error = reason; return false; };
    ModifierRuntime runtime;
    runtime._configured = true;
    runtime._stats = {{"country.test", COUNTRY, 0, 200}, {"cell.test", ECONOMY, 0, 200}};
    runtime._stat_ids = std::make_shared<const modifier_query::StatIds>(
        modifier_query::StatIds{{"country.test", 0}, {"cell.test", 1}});
    constexpr uint64_t pod_hash = 817;
    const auto catalog = runtime.make_read_catalog(pod_hash);
    RuntimeModifierPodSnapshot snapshot;
    snapshot.catalog_hash = pod_hash;
    ModifierReadView view;
    const auto copy = [](const RuntimeModifierPodSnapshot &s) {
        return std::make_shared<const RuntimeModifierPodSnapshot>(s);
    };
    if (!view.install(12, 12, 0, 0, copy(snapshot), catalog) || view.committed_day() != 0 ||
        view.modifier_generation() != 0 || view.stat_id_for_key("country.test") != 0 ||
        view.stat_id_for_key("unknown") != -1 || view.effective_value(COUNTRY, 0, 42, 0, 10) != 10)
        return fail("modifier_read_opening_frame");

    snapshot.committed_day = 4;
    snapshot.generation = 7;
    snapshot.domain_versions[COUNTRY] = 2;
    snapshot.buckets = {
        {COUNTRY, GLOBAL, 0, 0, 4, 1.5, 1}, {COUNTRY, GROUP, 0, 0, 100, 1, 1},
        {COUNTRY, ENTITY, 0, 42, 1, 2, 1}, {ECONOMY, GLOBAL, 1, 0, 1, 2, 1},
        {ECONOMY, GROUP, 1, 0, 2, 1, 1}, {ECONOMY, ENTITY, 1, 42, 3, 1, 1},
    };
    DerivedCellFront derived;
    DerivedCellStatRow row;
    row.stat_id = 1;
    row.cells = {0};
    DerivedCellContribution terms;
    terms.sum_add = 4;
    terms.product_nonzero = 0.5;
    row.contributions = {terms};
    derived.rows = {row};
    const auto front = std::make_shared<const DerivedCellFront>(derived);
    if (!view.install(12, 12, 4, 9, copy(snapshot), catalog, front) ||
        !runtime.apply_pod_snapshot(snapshot, error)) return fail("modifier_read_valid_install");
    runtime.restore_derived_cell_layer(derived);
    const auto retained = [&] {
        return view.session_epoch() == 12 && view.committed_day() == 4 && view.frame_generation() == 9 &&
            view.modifier_generation() == 7 && view.effective_value(COUNTRY, 0, 42, 0, 10) == 45 &&
            view.effective_value(ECONOMY, 1, 42, 0, 10) == 20;
    };
    if (!retained() || view.effective_value(COUNTRY, 0, 42, 0, 1000) != 200 ||
        view.effective_value(ECONOMY, 0, 42, 0, 10) != 10 ||
        view.effective_value(COUNTRY, 0, 42, 0, 10) != runtime.effective_value(COUNTRY, 0, 42, 0, 10) ||
        view.effective_value(ECONOMY, 1, 42, 0, 10) != runtime.effective_value(ECONOMY, 1, 42, 0, 10))
        return fail("modifier_read_value_differs");

    const auto refuses = [&](uint64_t source, int64_t day, uint64_t frame,
                             std::shared_ptr<const RuntimeModifierPodSnapshot> candidate) {
        return !view.install(12, source, day, frame, std::move(candidate), catalog) && retained();
    };
    if (!refuses(11, 4, 9, copy(snapshot))) return fail("modifier_read_accepted_other_session");
    if (!refuses(12, 4, 9, {})) return fail("modifier_read_accepted_null_snapshot");
    if (!refuses(12, 4, 8, copy(snapshot))) return fail("modifier_read_accepted_old_frame");
    if (!refuses(12, 5, 10, copy(snapshot))) return fail("modifier_read_accepted_wrong_day");
    auto candidate = snapshot;
    candidate.committed_day = 3;
    if (!refuses(12, 3, 10, copy(candidate))) return fail("modifier_read_accepted_old_day");
    candidate = snapshot;
    --candidate.generation;
    if (!refuses(12, 4, 10, copy(candidate))) return fail("modifier_read_accepted_old_modifier");
    candidate = snapshot;
    --candidate.domain_versions[COUNTRY];
    if (!refuses(12, 4, 9, copy(candidate))) return fail("modifier_read_accepted_old_domain");
    candidate = snapshot;
    ++candidate.catalog_hash;
    if (!refuses(12, 4, 9, copy(candidate))) return fail("modifier_read_accepted_wrong_catalog");
    candidate = snapshot;
    ++candidate.abi_version;
    if (!refuses(12, 4, 9, copy(candidate))) return fail("modifier_read_accepted_wrong_abi");
    if (view.install(12, 12, 4, 9, copy(snapshot), {}) || !retained())
        return fail("modifier_read_accepted_null_catalog");

    // Replacing an equally stamped day is legitimate. Its derived cell zero
    // and regular zero product must both survive; an older retained copy stays stable.
    const auto older = view;
    snapshot.buckets[2].product_factor = 0;
    ++snapshot.domain_versions[COUNTRY];
    derived.rows[0].contributions[0].zero_factor_count = 1;
    if (!view.install(12, 12, 4, 9, copy(snapshot), catalog, std::make_shared<const DerivedCellFront>(derived)) ||
        view.effective_value(COUNTRY, 0, 42, 0, 10) != 0 || view.effective_value(ECONOMY, 1, 42, 0, 10) != 0 ||
        older.effective_value(ECONOMY, 1, 42, 0, 10) != 20) return fail("modifier_read_same_day_replacement");
    RuntimeModifierPodSnapshot fresh;
    fresh.catalog_hash = pod_hash;
    if (!view.install(13, 13, 0, 0, copy(fresh), catalog) || view.session_epoch() != 13 ||
        view.effective_value(COUNTRY, 0, 42, 0, 10) != 10) return fail("modifier_read_new_world");
    if (!view.install(14, 14, 37, 0, copy(fresh), catalog) ||
        !view.install(14, 14, 37, 0, copy(fresh), catalog) ||
        view.install(14, 14, 38, 0, copy(fresh), catalog) ||
        view.install(14, 14, 37, 1, copy(fresh), catalog) ||
        view.committed_day() != 37 || view.frame_generation() != 0)
        return fail("modifier_read_nonzero_opening_calendar");
    return true;
}
} // namespace pk
