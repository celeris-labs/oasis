#include "arena.hpp"

#include <algorithm>
#include <iterator>
#include <linux/mman.h>
#include <stdexcept>
#include <sys/mman.h>

namespace oasis_s3 {

namespace {

constexpr uint64_t MIN_ALIGNMENT = 4096;

uint64_t align_up(uint64_t value, uint64_t alignment) {
    return (value + alignment - 1) / alignment * alignment;
}

} // namespace

Arena::Arena(uint64_t capacity) {
    if (capacity == 0) {
        throw std::invalid_argument("Arena capacity must not be zero");
    }

    // Prefer the largest pages the host has reserved, which also keeps the NIC's translation table
    // small. A reservation that is too small makes the mmap fail, so fall through to the next size.
    struct PageChoice {
        int         flags;
        uint64_t    size;
        const char *name;
    };
    static const PageChoice choices[] = {
        {MAP_HUGETLB | MAP_HUGE_1GB, 1ull << 30, "1 GiB"},
        {MAP_HUGETLB | MAP_HUGE_2MB, 1ull << 21, "2 MiB"},
    };
    for (const auto &choice : choices) {
        const uint64_t length = align_up(capacity, choice.size);
        void *mem = mmap(nullptr, length, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS | choice.flags, -1, 0);
        if (mem != MAP_FAILED) {
            mem_       = static_cast<uint8_t *>(mem);
            mapped_    = length;
            page_kind_ = choice.name;
            break;
        }
    }

    if (!mem_) {
        const uint64_t length = align_up(capacity, MIN_ALIGNMENT);
        void *mem = mmap(nullptr, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (mem == MAP_FAILED) {
            throw std::runtime_error("Could not map the object arena");
        }
        madvise(mem, length, MADV_HUGEPAGE); // Best effort, transparent huge pages may be disabled.
        mem_       = static_cast<uint8_t *>(mem);
        mapped_    = length;
        page_kind_ = "4 KiB (transparent huge pages if enabled)";
    }

    capacity_         = mapped_;
    free_extents_[0] = capacity_;
}

Arena::~Arena() {
    if (mem_) {
        munmap(mem_, mapped_);
    }
}

std::optional<uint64_t> Arena::allocate(uint64_t size) {
    const uint64_t length = align_up(std::max<uint64_t>(size, 1), MIN_ALIGNMENT);

    std::lock_guard<std::mutex> lock(mtx_);
    for (auto it = free_extents_.begin(); it != free_extents_.end(); ++it) {
        if (it->second < length) {
            continue;
        }
        const uint64_t offset    = it->first;
        const uint64_t remainder = it->second - length;
        free_extents_.erase(it);
        if (remainder > 0) {
            free_extents_[offset + length] = remainder;
        }
        used_ += length;
        return offset;
    }
    return std::nullopt;
}

void Arena::free(uint64_t offset, uint64_t size) {
    uint64_t length = align_up(std::max<uint64_t>(size, 1), MIN_ALIGNMENT);

    std::lock_guard<std::mutex> lock(mtx_);
    used_ -= length;

    auto next = free_extents_.lower_bound(offset);
    if (next != free_extents_.end() && offset + length == next->first) {
        length += next->second;
        next = free_extents_.erase(next);
    }
    if (next != free_extents_.begin()) {
        auto prev = std::prev(next);
        if (prev->first + prev->second == offset) {
            prev->second += length;
            return;
        }
    }
    free_extents_[offset] = length;
}

uint64_t Arena::used() const {
    std::lock_guard<std::mutex> lock(mtx_);
    return used_;
}

} // namespace oasis_s3
