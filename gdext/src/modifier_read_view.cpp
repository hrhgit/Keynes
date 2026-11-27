#include "modifier_runtime.h"
#include "modifier_value_query.h"

namespace pk {
class ModifierReadCatalog {
public:
    struct Stat { int32_t domain; double min_value, max_value; };
    uint64_t pod_hash = 0;
    std::shared_ptr<const modifier_query::StatIds> stat_ids;
    std::vector<Stat> stats;
};

std::shared_ptr<const ModifierReadCatalog> ModifierRuntime::make_read_catalog(uint64_t pod_catalog_hash) const {
    if (!_configured || !_stat_ids || !pod_catalog_hash) return {};
    auto catalog = std::make_shared<ModifierReadCatalog>();
    catalog->pod_hash = pod_catalog_hash;
    catalog->stat_ids = _stat_ids;
    catalog->stats.reserve(_stats.size());
    for (const auto &stat : _stats) catalog->stats.push_back({stat.domain, stat.min_value, stat.max_value});
    return catalog;
}

bool ModifierReadView::install(uint64_t expected_session, uint64_t source_session, int64_t day,
        uint64_t frame_generation, std::shared_ptr<const RuntimeModifierPodSnapshot> snapshot,
        std::shared_ptr<const ModifierReadCatalog> catalog, std::shared_ptr<const DerivedCellFront> derived) {
    if (!source_session || source_session != expected_session || day < 0 || !snapshot || !catalog ||
        snapshot->abi_version != RUNTIME_MODIFIER_POD_ABI_VERSION || snapshot->catalog_hash != catalog->pod_hash)
        return false;
    // A new world may open on a nonzero calendar date. Modifier itself has
    // no committed day until its first settlement. Only this first frame (or
    // a reissue of that same frame) can carry the initial -1 stamp.
    const bool first_frame = !_snapshot || source_session != _session ||
        (_frame_generation == 0 && _day == day && _snapshot->committed_day == -1);
    const bool opening = first_frame && frame_generation == 0 &&
        snapshot->generation == 0 && snapshot->committed_day == -1;
    if (!opening && snapshot->committed_day != day) return false;
    if (_snapshot && source_session == _session) {
        if (day < _day || frame_generation < _frame_generation || snapshot->generation < _snapshot->generation)
            return false;
        if (!std::equal(_snapshot->domain_versions.begin(), _snapshot->domain_versions.end(),
                        snapshot->domain_versions.begin(), std::less_equal<uint64_t>{})) return false;
    }
    _session = source_session;
    _day = day;
    _frame_generation = frame_generation;
    _snapshot = std::move(snapshot);
    _catalog = std::move(catalog);
    _derived = std::move(derived);
    return true;
}

uint64_t ModifierReadView::modifier_generation() const { return _snapshot ? _snapshot->generation : 0; }

int32_t ModifierReadView::stat_id_for_key(const std::string &key) const {
    return modifier_query::stat_id(_catalog ? _catalog->stat_ids.get() : nullptr, key);
}

double ModifierReadView::effective_value(int32_t domain, int32_t sid, uint64_t entity,
                                          uint64_t group, double base) const {
    if (!_catalog || !modifier_query::readable(_catalog->stats, domain, sid, base)) return base;
    const auto &buckets = _snapshot->buckets;
    const auto lookup = [&](int32_t scope, uint64_t handle) -> std::optional<modifier_query::Terms> {
        const auto key = std::make_tuple(static_cast<uint16_t>(domain), static_cast<uint16_t>(scope),
                                         static_cast<uint32_t>(sid), handle);
        const auto it = std::lower_bound(buckets.begin(), buckets.end(), key,
            [](const auto &bucket, const auto &wanted) { return bucket.key() < wanted; });
        if (it == buckets.end() || it->key() != key) return {};
        return modifier_query::Terms{it->sum_add, it->product_factor};
    };
    return modifier_query::effective(_catalog->stats[sid], sid, entity, group, base, _derived.get(), lookup);
}
} // namespace pk
