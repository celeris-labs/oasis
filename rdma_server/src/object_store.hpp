#pragma once

#include "arena.hpp"

#include <cstdint>
#include <ctime>
#include <map>
#include <memory>
#include <optional>
#include <shared_mutex>
#include <string>
#include <vector>

namespace oasis_s3 {

/**
 * One object: a contiguous arena extent plus its metadata. Readers hold a shared_ptr for the length
 * of a transfer, so overwriting or deleting a key never frees bytes that are still being sent.
 */
class Object {
  public:
    Object(Arena &arena, uint64_t offset, uint64_t size) : arena_(arena), offset_(offset), size_(size) {}
    ~Object() { arena_.free(offset_, size_); }

    Object(const Object &)            = delete;
    Object &operator=(const Object &) = delete;

    [[nodiscard]] uint8_t *data() const { return arena_.data() + offset_; }
    [[nodiscard]] uint64_t size() const { return size_; }

    std::string etag;
    std::string content_type = "binary/octet-stream";
    std::time_t last_modified = 0;

  private:
    Arena   &arena_;
    uint64_t offset_;
    uint64_t size_;
};

using ObjectPtr = std::shared_ptr<Object>;

// Hex MD5 of [data, data + size), the conventional S3 ETag.
std::string md5_hex(const uint8_t *data, uint64_t size);
std::string quoted(const std::string &value);

struct ListResult {
    std::vector<std::pair<std::string, ObjectPtr>> objects;
    std::vector<std::string>                       common_prefixes;
    bool                                           truncated = false;
    std::string                                    next_token;
};

struct UploadedPart {
    int         number = 0;
    std::string etag;
};

enum class StoreError { none, no_such_bucket, no_such_key, bucket_exists, bucket_not_empty,
                        no_such_upload, invalid_part, out_of_space };

class ObjectStore {
  public:
    explicit ObjectStore(Arena &arena) : arena_(arena) {}

    // Reserves an uncommitted object of `size` bytes, or returns nullptr if the arena is full.
    ObjectPtr allocate(uint64_t size);

    StoreError                 create_bucket(const std::string &bucket);
    StoreError                 delete_bucket(const std::string &bucket);
    [[nodiscard]] bool         bucket_exists(const std::string &bucket) const;
    [[nodiscard]] std::vector<std::string> list_buckets() const;

    // Atomically replaces the key. The caller has already filled the object and set its metadata.
    StoreError                 put(const std::string &bucket, const std::string &key, ObjectPtr object);
    [[nodiscard]] ObjectPtr    get(const std::string &bucket, const std::string &key) const;
    StoreError                 remove(const std::string &bucket, const std::string &key);

    // Keys strictly after `after` that start with `prefix`, grouped on `delimiter` if it is set.
    [[nodiscard]] ListResult   list(const std::string &bucket, const std::string &prefix,
                                    const std::string &delimiter, const std::string &after,
                                    size_t max_keys) const;

    std::string                create_upload(const std::string &bucket, const std::string &key);
    StoreError                 put_part(const std::string &upload_id, int number, ObjectPtr part);
    StoreError                 abort_upload(const std::string &upload_id);
    // Compacts the listed parts into one contiguous extent: transfers rely on objects being one
    // extent, and the parts themselves were allocated independently as they arrived.
    StoreError                 complete_upload(const std::string &upload_id,
                                               const std::vector<UploadedPart> &parts,
                                               ObjectPtr &completed);

  private:
    using Bucket = std::map<std::string, ObjectPtr>;

    struct Upload {
        std::string              bucket;
        std::string              key;
        std::map<int, ObjectPtr> parts;
    };

    Arena                        &arena_;
    mutable std::shared_mutex     mtx_;
    std::map<std::string, Bucket> buckets_;
    std::map<std::string, Upload> uploads_;
    uint64_t                      next_upload_id_ = 1;
};

} // namespace oasis_s3
