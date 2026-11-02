#include "object_store.hpp"

#include <boost/uuid/detail/md5.hpp>

#include <cstdio>
#include <cstring>
#include <mutex>

namespace oasis_s3 {

namespace {

using Md5 = boost::uuids::detail::md5;

std::string digest_to_hex(const Md5::digest_type &digest) {
    char hex[33];
    for (size_t i = 0; i < 4; ++i) {
        std::snprintf(hex + 8 * i, 9, "%08x", digest[i]);
    }
    return std::string(hex, 32);
}

bool starts_with(const std::string &value, const std::string &prefix) {
    return value.compare(0, prefix.size(), prefix) == 0;
}

std::string strip_quotes(const std::string &etag) {
    if (etag.size() >= 2 && etag.front() == '"' && etag.back() == '"') {
        return etag.substr(1, etag.size() - 2);
    }
    return etag;
}

} // namespace

std::string md5_hex(const uint8_t *data, uint64_t size) {
    Md5 hash;
    hash.process_bytes(data, size);
    Md5::digest_type digest;
    hash.get_digest(digest);
    return digest_to_hex(digest);
}

std::string quoted(const std::string &value) {
    return "\"" + value + "\"";
}

ObjectPtr ObjectStore::allocate(uint64_t size) {
    const auto offset = arena_.allocate(size);
    if (!offset) {
        return nullptr;
    }
    return std::make_shared<Object>(arena_, *offset, size);
}

StoreError ObjectStore::create_bucket(const std::string &bucket) {
    std::unique_lock lock(mtx_);
    return buckets_.try_emplace(bucket).second ? StoreError::none : StoreError::bucket_exists;
}

StoreError ObjectStore::delete_bucket(const std::string &bucket) {
    std::unique_lock lock(mtx_);
    auto             it = buckets_.find(bucket);
    if (it == buckets_.end()) {
        return StoreError::no_such_bucket;
    }
    if (!it->second.empty()) {
        return StoreError::bucket_not_empty;
    }
    buckets_.erase(it);
    return StoreError::none;
}

bool ObjectStore::bucket_exists(const std::string &bucket) const {
    std::shared_lock lock(mtx_);
    return buckets_.count(bucket) != 0;
}

std::vector<std::string> ObjectStore::list_buckets() const {
    std::shared_lock         lock(mtx_);
    std::vector<std::string> names;
    names.reserve(buckets_.size());
    for (const auto &bucket : buckets_) {
        names.push_back(bucket.first);
    }
    return names;
}

StoreError ObjectStore::put(const std::string &bucket, const std::string &key, ObjectPtr object) {
    // Swap under the lock but let any replaced object die outside of it, since freeing takes the
    // arena's lock.
    ObjectPtr replaced;
    {
        std::unique_lock lock(mtx_);
        auto             it = buckets_.find(bucket);
        if (it == buckets_.end()) {
            return StoreError::no_such_bucket;
        }
        auto &slot = it->second[key];
        replaced   = std::move(slot);
        slot       = std::move(object);
    }
    return StoreError::none;
}

ObjectPtr ObjectStore::get(const std::string &bucket, const std::string &key) const {
    std::shared_lock lock(mtx_);
    auto             bucket_it = buckets_.find(bucket);
    if (bucket_it == buckets_.end()) {
        return nullptr;
    }
    auto object_it = bucket_it->second.find(key);
    return object_it == bucket_it->second.end() ? nullptr : object_it->second;
}

StoreError ObjectStore::remove(const std::string &bucket, const std::string &key) {
    ObjectPtr removed;
    {
        std::unique_lock lock(mtx_);
        auto             it = buckets_.find(bucket);
        if (it == buckets_.end()) {
            return StoreError::no_such_bucket;
        }
        // S3 reports success for a key that does not exist.
        auto object_it = it->second.find(key);
        if (object_it != it->second.end()) {
            removed = std::move(object_it->second);
            it->second.erase(object_it);
        }
    }
    return StoreError::none;
}

ListResult ObjectStore::list(const std::string &bucket, const std::string &prefix,
                             const std::string &delimiter, const std::string &after,
                             size_t max_keys) const {
    ListResult       result;
    std::shared_lock lock(mtx_);

    auto bucket_it = buckets_.find(bucket);
    if (bucket_it == buckets_.end() || max_keys == 0) {
        return result;
    }
    const Bucket &objects = bucket_it->second;

    auto it = (after.empty() || after < prefix) ? objects.lower_bound(prefix) : objects.upper_bound(after);
    // A token naming a common prefix resumes behind every key that was rolled up into it.
    const bool after_is_rollup = !delimiter.empty() && after.size() >= delimiter.size() &&
                                 after.compare(after.size() - delimiter.size(), delimiter.size(),
                                               delimiter) == 0;

    size_t count = 0;
    for (; it != objects.end() && starts_with(it->first, prefix); ++it) {
        const std::string &key = it->first;
        if (after_is_rollup && starts_with(key, after)) {
            continue;
        }

        std::string rollup;
        if (!delimiter.empty()) {
            const size_t found = key.find(delimiter, prefix.size());
            if (found != std::string::npos) {
                rollup = key.substr(0, found + delimiter.size());
            }
        }
        if (!rollup.empty() && !result.common_prefixes.empty() && result.common_prefixes.back() == rollup) {
            continue;
        }

        if (count == max_keys) {
            result.truncated = true;
            break;
        }
        if (!rollup.empty()) {
            result.common_prefixes.push_back(rollup);
            result.next_token = rollup;
        } else {
            result.objects.emplace_back(key, it->second);
            result.next_token = key;
        }
        ++count;
    }
    if (!result.truncated) {
        result.next_token.clear();
    }
    return result;
}

std::string ObjectStore::create_upload(const std::string &bucket, const std::string &key) {
    std::unique_lock lock(mtx_);
    std::string      id = "oasis-" + std::to_string(next_upload_id_++);
    uploads_[id]        = Upload{bucket, key, {}};
    return id;
}

StoreError ObjectStore::put_part(const std::string &upload_id, int number, ObjectPtr part) {
    ObjectPtr replaced;
    {
        std::unique_lock lock(mtx_);
        auto             it = uploads_.find(upload_id);
        if (it == uploads_.end()) {
            return StoreError::no_such_upload;
        }
        auto &slot = it->second.parts[number];
        replaced   = std::move(slot);
        slot       = std::move(part);
    }
    return StoreError::none;
}

StoreError ObjectStore::abort_upload(const std::string &upload_id) {
    Upload aborted;
    {
        std::unique_lock lock(mtx_);
        auto             it = uploads_.find(upload_id);
        if (it == uploads_.end()) {
            return StoreError::no_such_upload;
        }
        aborted = std::move(it->second);
        uploads_.erase(it);
    }
    return StoreError::none;
}

StoreError ObjectStore::complete_upload(const std::string               &upload_id,
                                        const std::vector<UploadedPart> &parts,
                                        ObjectPtr                       &completed) {
    // Work on a copy of the part list: a rejected completion leaves the upload in place, so the
    // client can retry it, and only success removes it below.
    Upload upload;
    {
        std::shared_lock lock(mtx_);
        auto             it = uploads_.find(upload_id);
        if (it == uploads_.end()) {
            return StoreError::no_such_upload;
        }
        upload = it->second;
    }

    uint64_t                 total = 0;
    std::vector<ObjectPtr>   ordered;
    ordered.reserve(parts.size());
    for (const auto &part : parts) {
        auto it = upload.parts.find(part.number);
        if (it == upload.parts.end() || strip_quotes(part.etag) != it->second->etag) {
            return StoreError::invalid_part;
        }
        total += it->second->size();
        ordered.push_back(it->second);
    }

    completed = allocate(total);
    if (!completed) {
        return StoreError::out_of_space;
    }

    // The multipart ETag convention: the MD5 of the concatenated binary part digests, then "-N".
    Md5      hash;
    uint64_t cursor = 0;
    for (const auto &part : ordered) {
        std::memcpy(completed->data() + cursor, part->data(), part->size());
        cursor += part->size();

        uint8_t binary[16];
        for (size_t i = 0; i < 16; ++i) {
            unsigned value = 0;
            std::sscanf(part->etag.c_str() + 2 * i, "%2x", &value);
            binary[i] = static_cast<uint8_t>(value);
        }
        hash.process_bytes(binary, sizeof(binary));
    }
    Md5::digest_type digest;
    hash.get_digest(digest);
    completed->etag          = digest_to_hex(digest) + "-" + std::to_string(ordered.size());
    completed->last_modified = std::time(nullptr);

    // The parts' shared_ptrs in `upload` and `ordered` free them when this function returns.
    std::unique_lock lock(mtx_);
    uploads_.erase(upload_id);
    return StoreError::none;
}

} // namespace oasis_s3
