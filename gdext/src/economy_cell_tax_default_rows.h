#pragma once

#include <array>
#include <cstdint>
#include <map>

namespace pk {

// Local to one tax freeze. Zero denotes a new entry; stored row numbers start at one.
class CellTaxDefaultRows {
public:
    int32_t &row_number(int32_t country, int32_t kind, int32_t amount, int32_t mode) {
        return _rows[{country, kind, amount, mode}];
    }

private:
    std::map<std::array<int32_t, 4>, int32_t> _rows;
};

} // namespace pk
