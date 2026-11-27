#include "economy_cell_tax_default_rows.h"

#include <algorithm>
#include <limits>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace pk {

bool test_cell_tax_default_rows(std::string &error) {
    constexpr int64_t bit = int64_t{1} << 24;
    constexpr auto min_amount = std::numeric_limits<int32_t>::min();
    constexpr auto max_amount = std::numeric_limits<int32_t>::max();
    // Storage distinguishes signed amounts independently of policy validation.
    // Include both modes at every representable bit-24 transition and at the
    // current policy endpoints, so tightening a rate limit cannot hide aliasing.
    std::set<int32_t> amounts{min_amount, max_amount, -1000000000, 1000000000,
        -100000, 10000, -118, 118};
    for (int64_t boundary = min_amount; boundary <= max_amount; boundary += bit) {
        for (int32_t delta : {-1, 0, 1}) {
            const int64_t amount = boundary + delta;
            if (amount >= min_amount && amount <= max_amount)
                amounts.insert(static_cast<int32_t>(amount));
        }
    }
    std::vector<std::pair<int32_t, int32_t>> policies;
    for (int32_t amount : amounts) {
        for (int32_t mode : {0, 1}) policies.emplace_back(amount, mode);
    }
    int collisions = 0;
    for (int order = 0; order < 2; ++order) {
        CellTaxDefaultRows rows;
        for (int pass = 0; pass < 2; ++pass) {
            int32_t expected = 0;
            for (int32_t country : {0, 1}) {
                for (int32_t kind : {0, 1, 2, 3, 4}) {
                    for (const auto &[amount, mode] : policies) {
                        ++expected;
                        int32_t &number = rows.row_number(country, kind, amount, mode);
                        if ((pass == 0 && number != 0) || (pass == 1 && number != expected)) {
                            if (collisions == 0) {
                                error = "cell_tax_default_row: country=" + std::to_string(country) +
                                    " kind=" + std::to_string(kind) + " amount=" + std::to_string(amount) +
                                    " mode=" + std::to_string(mode) + " prior_row=" + std::to_string(number);
                            }
                            ++collisions;
                        }
                        if (pass == 0 && number == 0) number = expected;
                    }
                }
            }
        }
        std::reverse(policies.begin(), policies.end());
    }
    if (collisions) error += " failed_checks=" + std::to_string(collisions);
    return collisions == 0;
}

} // namespace pk
