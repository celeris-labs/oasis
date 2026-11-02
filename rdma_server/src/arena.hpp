#pragma once

#include <cstddef>
#include <cstdint>
#include <map>
#include <mutex>
#include <optional>

namespace oasis_s3 {

/**
 * The one memory region every object lives in. It is backed by the largest huge pages available and
 * is registered with the NIC once at startup, so no transfer ever pays for a registration.
 */
class Arena {
  public:
    explicit Arena(uint64_t capacity);
    ~Arena();

    Arena(const Arena &)            = delete;
    Arena &operator=(const Arena &) = delete;

    // Reserves a contiguous extent and returns its offset, or nullopt if no gap is large enough.
    std::optional<uint64_t> allocate(uint64_t size);
    void                    free(uint64_t offset, uint64_t size);

    [[nodiscard]] uint8_t    *data() const { return mem_; }
    [[nodiscard]] uint64_t    capacity() const { return capacity_; }
    [[nodiscard]] uint64_t    used() const;
    [[nodiscard]] const char *page_kind() const { return page_kind_; }

  private:
    uint8_t    *mem_       = nullptr;
    uint64_t    capacity_  = 0;
    uint64_t    mapped_    = 0;
    const char *page_kind_ = "4 KiB";

    mutable std::mutex           mtx_;
    std::map<uint64_t, uint64_t> free_extents_; // offset -> size, coalesced
    uint64_t                     used_ = 0;
};

} // namespace oasis_s3
