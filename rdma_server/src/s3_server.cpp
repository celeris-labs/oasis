#include "s3_server.hpp"

#include <boost/asio.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>

#include <algorithm>
#include <arpa/inet.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <iostream>
#include <list>
#include <map>
#include <memory>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <optional>
#include <poll.h>
#include <sstream>
#include <sys/socket.h>
#include <unistd.h>

namespace oasis_s3 {

namespace {

namespace asio  = boost::asio;
namespace beast = boost::beast;
namespace http  = beast::http;
using tcp       = asio::ip::tcp;

constexpr size_t   DEFAULT_MAX_KEYS   = 1000;
constexpr uint32_t MAX_HEADER_BYTES   = 64 * 1024;
constexpr int      MAX_PART_NUMBER    = 10000;
constexpr int      BACKLOG            = 1024;
constexpr size_t   MAX_CONNECTIONS    = 4096;
constexpr const char *XML_DECLARATION = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
constexpr const char *XML_NAMESPACE   = "http://s3.amazonaws.com/doc/2006-03-01/";

using Request  = http::request<http::string_body>;
using QueryMap = std::map<std::string, std::string>;

// -- Text helpers ---------------------------------------------------------------------------------
int hex_digit(char c) {
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

std::string percent_decode(const std::string &text, bool plus_is_space) {
    std::string out;
    out.reserve(text.size());
    for (size_t i = 0; i < text.size(); ++i) {
        if (text[i] == '%' && i + 2 < text.size() && hex_digit(text[i + 1]) >= 0 &&
            hex_digit(text[i + 2]) >= 0) {
            out.push_back(static_cast<char>(hex_digit(text[i + 1]) * 16 + hex_digit(text[i + 2])));
            i += 2;
        } else if (text[i] == '+' && plus_is_space) {
            out.push_back(' ');
        } else {
            out.push_back(text[i]);
        }
    }
    return out;
}

std::string uri_encode(const std::string &text) {
    static const char *digits = "0123456789ABCDEF";
    std::string        out;
    out.reserve(text.size());
    for (unsigned char c : text) {
        if (std::isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~' || c == '/') {
            out.push_back(static_cast<char>(c));
        } else {
            out.push_back('%');
            out.push_back(digits[c >> 4]);
            out.push_back(digits[c & 0xf]);
        }
    }
    return out;
}

std::string xml_escape(const std::string &text) {
    std::string out;
    out.reserve(text.size());
    for (char c : text) {
        switch (c) {
        case '&':
            out += "&amp;";
            break;
        case '<':
            out += "&lt;";
            break;
        case '>':
            out += "&gt;";
            break;
        case '"':
            out += "&quot;";
            break;
        case '\'':
            out += "&apos;";
            break;
        default:
            out.push_back(c);
        }
    }
    return out;
}

std::string xml_unescape(const std::string &text) {
    static const std::pair<const char *, char> entities[] = {
        {"&amp;", '&'}, {"&lt;", '<'}, {"&gt;", '>'}, {"&quot;", '"'}, {"&apos;", '\''}};
    std::string out;
    out.reserve(text.size());
    for (size_t i = 0; i < text.size();) {
        bool matched = false;
        for (const auto &entity : entities) {
            const size_t length = std::strlen(entity.first);
            if (text.compare(i, length, entity.first) == 0) {
                out.push_back(entity.second);
                i += length;
                matched = true;
                break;
            }
        }
        if (!matched) {
            out.push_back(text[i++]);
        }
    }
    return out;
}

// All values of <tag>...</tag> in `xml`. Enough for the flat documents S3 clients send.
std::vector<std::string> xml_values(const std::string &xml, const std::string &tag) {
    std::vector<std::string> values;
    const std::string        open  = "<" + tag + ">";
    const std::string        close = "</" + tag + ">";
    size_t                   pos   = 0;
    while ((pos = xml.find(open, pos)) != std::string::npos) {
        const size_t begin = pos + open.size();
        const size_t end   = xml.find(close, begin);
        if (end == std::string::npos) {
            break;
        }
        values.push_back(xml_unescape(xml.substr(begin, end - begin)));
        pos = end + close.size();
    }
    return values;
}

std::string http_date(std::time_t time) {
    char    text[64];
    std::tm tm_utc;
    gmtime_r(&time, &tm_utc);
    std::strftime(text, sizeof(text), "%a, %d %b %Y %H:%M:%S GMT", &tm_utc);
    return text;
}

std::string iso8601_date(std::time_t time) {
    char    text[64];
    std::tm tm_utc;
    gmtime_r(&time, &tm_utc);
    std::strftime(text, sizeof(text), "%Y-%m-%dT%H:%M:%S.000Z", &tm_utc);
    return text;
}

std::string header(const Request &req, const char *name) {
    auto it = req.find(name);
    return it == req.end() ? std::string() : std::string(it->value());
}

// -- Request parsing ------------------------------------------------------------------------------
struct Target {
    std::string bucket;
    std::string key;
    QueryMap    query;
};

Target parse_target(const std::string &raw) {
    Target       target;
    const size_t mark  = raw.find('?');
    std::string  path  = percent_decode(raw.substr(0, mark), false);
    if (mark != std::string::npos) {
        std::stringstream parts(raw.substr(mark + 1));
        std::string       part;
        while (std::getline(parts, part, '&')) {
            if (part.empty()) {
                continue;
            }
            const size_t equals = part.find('=');
            target.query[percent_decode(part.substr(0, equals), true)] =
                equals == std::string::npos ? "" : percent_decode(part.substr(equals + 1), true);
        }
    }

    if (!path.empty() && path.front() == '/') {
        path.erase(0, 1);
    }
    const size_t slash = path.find('/');
    target.bucket      = path.substr(0, slash);
    target.key         = slash == std::string::npos ? "" : path.substr(slash + 1);
    return target;
}

struct ByteRange {
    uint64_t first = 0;
    uint64_t last  = 0;
};

enum class RangeResult { none, valid, invalid };

RangeResult parse_range(const std::string &text, uint64_t size, ByteRange &range) {
    if (text.empty()) {
        return RangeResult::none;
    }
    static const std::string prefix = "bytes=";
    const size_t             dash   = text.find('-');
    // A multi-range request may be answered with the whole object, which S3 does as well.
    if (text.compare(0, prefix.size(), prefix) != 0 || dash == std::string::npos ||
        text.find(',') != std::string::npos) {
        return RangeResult::none;
    }
    const std::string first = text.substr(prefix.size(), dash - prefix.size());
    const std::string last  = text.substr(dash + 1);
    try {
        if (first.empty()) {
            const uint64_t suffix = std::stoull(last);
            if (suffix == 0 || size == 0) {
                return RangeResult::invalid;
            }
            range.first = suffix >= size ? 0 : size - suffix;
            range.last  = size - 1;
        } else {
            range.first = std::stoull(first);
            range.last  = last.empty() ? size - 1 : std::min<uint64_t>(std::stoull(last), size - 1);
            if (range.first >= size || range.first > range.last) {
                return RangeResult::invalid;
            }
        }
    } catch (const std::exception &) {
        return RangeResult::none;
    }
    return RangeResult::valid;
}

// Decodes the aws-chunked framing current AWS SDKs put around PutObject and UploadPart bodies:
// "<hex-size>[;chunk-signature=...]\r\n<data>\r\n", ended by a zero-size chunk and optional trailers.
bool decode_aws_chunked(const std::string &body, std::string &out) {
    size_t pos = 0;
    while (true) {
        const size_t line_end = body.find("\r\n", pos);
        if (line_end == std::string::npos) {
            return false;
        }
        const std::string size_text = body.substr(pos, body.find(';', pos) < line_end
                                                           ? body.find(';', pos) - pos
                                                           : line_end - pos);
        uint64_t          size      = 0;
        try {
            size = std::stoull(size_text, nullptr, 16);
        } catch (const std::exception &) {
            return false;
        }
        pos = line_end + 2;
        if (size == 0) {
            return true;
        }
        if (pos + size > body.size()) {
            return false;
        }
        out.append(body, pos, size);
        pos += size + 2;
    }
}

bool is_aws_chunked(const Request &req) {
    return header(req, "x-amz-content-sha256").rfind("STREAMING-", 0) == 0 ||
           header(req, "content-encoding").find("aws-chunked") != std::string::npos;
}

// -- Responses ------------------------------------------------------------------------------------
class Responder {
  public:
    Responder(tcp::socket &socket, const Request &req) : socket_(socket), req_(req) {}

    [[nodiscard]] bool ok() const { return !failed_; }

    template <typename Body> void send(http::response<Body> &res) {
        res.version(req_.version());
        res.keep_alive(req_.keep_alive());
        res.set(http::field::server, "OasisS3");
        res.set(http::field::date, http_date(std::time(nullptr)));
        res.set("x-amz-request-id", "oasis");
        beast::error_code ec;
        http::write(socket_, res, ec);
        failed_ = static_cast<bool>(ec);
    }

    void xml(http::status status, const std::string &body) {
        http::response<http::string_body> res{status, req_.version()};
        res.set(http::field::content_type, "application/xml");
        res.body() = body;
        res.prepare_payload();
        if (req_.method() == http::verb::head) {
            http::response<http::empty_body> head{status, req_.version()};
            head.set(http::field::content_type, "application/xml");
            head.content_length(body.size());
            send(head);
            return;
        }
        send(res);
    }

    void error(http::status status, const std::string &code, const std::string &message,
               const char *rdma_reply = nullptr) {
        std::ostringstream body;
        body << XML_DECLARATION << "<Error><Code>" << code << "</Code><Message>"
             << xml_escape(message) << "</Message><Resource>" << xml_escape(std::string(req_.target()))
             << "</Resource><RequestId>oasis</RequestId></Error>";
        http::response<http::string_body> res{status, req_.version()};
        res.set(http::field::content_type, "application/xml");
        if (rdma_reply) {
            res.set(RDMA_REPLY_HEADER, rdma_reply);
        }
        res.body() = body.str();
        res.prepare_payload();
        if (req_.method() == http::verb::head) {
            http::response<http::empty_body> head{status, req_.version()};
            if (rdma_reply) {
                head.set(RDMA_REPLY_HEADER, rdma_reply);
            }
            head.content_length(0);
            send(head);
            return;
        }
        send(res);
    }

    void empty(http::status status) {
        http::response<http::empty_body> res{status, req_.version()};
        res.content_length(0);
        send(res);
    }

    void store_error(StoreError error_code, const std::string &bucket) {
        switch (error_code) {
        case StoreError::no_such_bucket:
            error(http::status::not_found, "NoSuchBucket", "The bucket " + bucket + " does not exist");
            break;
        case StoreError::no_such_key:
            error(http::status::not_found, "NoSuchKey", "The key does not exist");
            break;
        case StoreError::bucket_exists:
            error(http::status::conflict, "BucketAlreadyOwnedByYou", "The bucket already exists");
            break;
        case StoreError::bucket_not_empty:
            error(http::status::conflict, "BucketNotEmpty", "The bucket is not empty");
            break;
        case StoreError::no_such_upload:
            error(http::status::not_found, "NoSuchUpload", "The upload does not exist");
            break;
        case StoreError::invalid_part:
            error(http::status::bad_request, "InvalidPart", "A listed part is missing or has another ETag");
            break;
        case StoreError::out_of_space:
            error(http::status::insufficient_storage, "InsufficientStorage", "The object arena is full");
            break;
        case StoreError::none:
            break;
        }
    }

  private:
    tcp::socket   &socket_;
    const Request &req_;
    bool           failed_ = false;
};

void set_object_headers(http::response_header<> &res, const Object &object) {
    res.set(http::field::etag, quoted(object.etag));
    res.set(http::field::last_modified, http_date(object.last_modified));
    res.set(http::field::content_type, object.content_type);
    res.set(http::field::accept_ranges, "bytes");
}

// -- Handlers -------------------------------------------------------------------------------------
class Handler {
  public:
    Handler(ObjectStore &store, RdmaEngine *engine, const Request &req, tcp::socket &socket)
        : store_(store), engine_(engine), req_(req), target_(parse_target(std::string(req.target()))),
          respond_(socket, req) {}

    bool run() {
        if (req_.method() == http::verb::post && req_.target() == RDMA_CONNECT_PATH) {
            rdma_connect();
        } else if (target_.bucket.empty()) {
            service();
        } else if (target_.key.empty()) {
            bucket();
        } else {
            object();
        }
        return respond_.ok();
    }

  private:
    void not_implemented(const std::string &what) {
        respond_.error(http::status::not_implemented, "NotImplemented", what + " is not implemented");
    }

    // A token is honored only on GetObject, PutObject and UploadPart, as in AIStor. Anything other
    // than a well-formed token for a live session gets one of the documented refusals.
    std::optional<RdmaToken> usable_token(bool &refused) {
        refused                = false;
        const std::string text = header(req_, RDMA_TOKEN_HEADER);
        if (text.empty()) {
            return std::nullopt;
        }
        const auto token = parse_token(text);
        if (!token) {
            // A malformed token is a plain S3 error, without the reply header.
            respond_.error(http::status::bad_request, "InvalidArgument", "Malformed x-amz-rdma-token");
            refused = true;
            return std::nullopt;
        }
        if (!engine_) {
            decline_rdma("RDMA is disabled on this server");
            refused = true;
            return std::nullopt;
        }
        return token;
    }

    void decline_rdma(const std::string &why) {
        respond_.error(http::status::not_implemented, "NotImplemented", why, "501");
    }

    void rdma_connect() {
        bool       refused = false;
        const auto token   = usable_token(refused);
        if (refused) {
            return;
        }
        if (!token) {
            respond_.error(http::status::bad_request, "InvalidArgument", "Missing x-amz-rdma-token");
            return;
        }
        if (!token->gid_present) {
            decline_rdma("RoCE needs the GID of the client's QP");
            return;
        }
        const auto local = engine_->connect(*token);
        if (!local) {
            decline_rdma("Could not create an RDMA session");
            return;
        }
        http::response<http::empty_body> res{http::status::ok, req_.version()};
        res.set(RDMA_REPLY_HEADER, "200:" + format_token(*local));
        res.content_length(0);
        respond_.send(res);
    }

    void service() {
        if (req_.method() != http::verb::get) {
            respond_.error(http::status::method_not_allowed, "MethodNotAllowed", "Unsupported method");
            return;
        }
        std::ostringstream xml;
        xml << XML_DECLARATION << "<ListAllMyBucketsResult xmlns=\"" << XML_NAMESPACE
            << "\"><Owner><ID>oasis</ID><DisplayName>oasis</DisplayName></Owner><Buckets>";
        const std::string now = iso8601_date(std::time(nullptr));
        for (const auto &name : store_.list_buckets()) {
            xml << "<Bucket><Name>" << xml_escape(name) << "</Name><CreationDate>" << now
                << "</CreationDate></Bucket>";
        }
        xml << "</Buckets></ListAllMyBucketsResult>";
        respond_.xml(http::status::ok, xml.str());
    }

    void bucket() {
        const std::string &name = target_.bucket;
        switch (req_.method()) {
        case http::verb::put:
            if (!target_.query.empty()) {
                return not_implemented("This bucket subresource");
            }
            if (const StoreError error = store_.create_bucket(name); error != StoreError::none) {
                return respond_.store_error(error, name);
            }
            return respond_.empty(http::status::ok);
        case http::verb::delete_:
            if (const StoreError error = store_.delete_bucket(name); error != StoreError::none) {
                return respond_.store_error(error, name);
            }
            return respond_.empty(http::status::no_content);
        case http::verb::head:
            if (!store_.bucket_exists(name)) {
                return respond_.store_error(StoreError::no_such_bucket, name);
            }
            return respond_.empty(http::status::ok);
        case http::verb::post:
            if (target_.query.count("delete") != 0) {
                return delete_objects();
            }
            return not_implemented("This bucket POST");
        case http::verb::get:
            if (!store_.bucket_exists(name)) {
                return respond_.store_error(StoreError::no_such_bucket, name);
            }
            if (target_.query.count("location") != 0) {
                std::ostringstream xml;
                xml << XML_DECLARATION << "<LocationConstraint xmlns=\"" << XML_NAMESPACE
                    << "\"></LocationConstraint>";
                return respond_.xml(http::status::ok, xml.str());
            }
            for (const char *unsupported : {"uploads", "versioning", "acl", "policy", "lifecycle", "versions"}) {
                if (target_.query.count(unsupported) != 0) {
                    return not_implemented(std::string("The ") + unsupported + " subresource");
                }
            }
            return list_objects();
        default:
            respond_.error(http::status::method_not_allowed, "MethodNotAllowed", "Unsupported method");
        }
    }

    std::string query_value(const char *name) const {
        auto it = target_.query.find(name);
        return it == target_.query.end() ? std::string() : it->second;
    }

    void list_objects() {
        const bool        v2        = query_value("list-type") == "2";
        const std::string prefix    = query_value("prefix");
        const std::string delimiter = query_value("delimiter");
        const std::string token     = query_value("continuation-token");
        const std::string start     = v2 ? query_value("start-after") : query_value("marker");
        const bool        url_keys  = query_value("encoding-type") == "url";
        const std::string after     = v2 && !token.empty() ? token : start;

        size_t max_keys = DEFAULT_MAX_KEYS;
        if (const std::string text = query_value("max-keys"); !text.empty()) {
            try {
                max_keys = std::min<size_t>(std::stoull(text), DEFAULT_MAX_KEYS);
            } catch (const std::exception &) {
                return respond_.error(http::status::bad_request, "InvalidArgument", "Invalid max-keys");
            }
        }

        const auto encode = [&](const std::string &text) {
            return xml_escape(url_keys ? uri_encode(text) : text);
        };

        const ListResult   result = store_.list(target_.bucket, prefix, delimiter, after, max_keys);
        std::ostringstream xml;
        xml << XML_DECLARATION << "<ListBucketResult xmlns=\"" << XML_NAMESPACE << "\"><Name>"
            << xml_escape(target_.bucket) << "</Name><Prefix>" << encode(prefix) << "</Prefix>";
        if (!delimiter.empty()) {
            xml << "<Delimiter>" << encode(delimiter) << "</Delimiter>";
        }
        if (url_keys) {
            xml << "<EncodingType>url</EncodingType>";
        }
        xml << "<MaxKeys>" << max_keys << "</MaxKeys><IsTruncated>"
            << (result.truncated ? "true" : "false") << "</IsTruncated>";
        if (v2) {
            xml << "<KeyCount>" << result.objects.size() + result.common_prefixes.size() << "</KeyCount>";
            if (!token.empty()) {
                xml << "<ContinuationToken>" << xml_escape(token) << "</ContinuationToken>";
            }
            if (result.truncated) {
                xml << "<NextContinuationToken>" << xml_escape(result.next_token)
                    << "</NextContinuationToken>";
            }
        } else {
            xml << "<Marker>" << encode(start) << "</Marker>";
            if (result.truncated) {
                xml << "<NextMarker>" << encode(result.next_token) << "</NextMarker>";
            }
        }
        for (const auto &entry : result.objects) {
            xml << "<Contents><Key>" << encode(entry.first) << "</Key><LastModified>"
                << iso8601_date(entry.second->last_modified) << "</LastModified><ETag>"
                << xml_escape(quoted(entry.second->etag)) << "</ETag><Size>" << entry.second->size()
                << "</Size><StorageClass>STANDARD</StorageClass></Contents>";
        }
        for (const auto &common : result.common_prefixes) {
            xml << "<CommonPrefixes><Prefix>" << encode(common) << "</Prefix></CommonPrefixes>";
        }
        xml << "</ListBucketResult>";
        respond_.xml(http::status::ok, xml.str());
    }

    void delete_objects() {
        const bool         quiet = xml_values(req_.body(), "Quiet") == std::vector<std::string>{"true"};
        std::ostringstream xml;
        xml << XML_DECLARATION << "<DeleteResult xmlns=\"" << XML_NAMESPACE << "\">";
        for (const auto &key : xml_values(req_.body(), "Key")) {
            const StoreError error = store_.remove(target_.bucket, key);
            if (error != StoreError::none) {
                return respond_.store_error(error, target_.bucket);
            }
            if (!quiet) {
                xml << "<Deleted><Key>" << xml_escape(key) << "</Key></Deleted>";
            }
        }
        xml << "</DeleteResult>";
        respond_.xml(http::status::ok, xml.str());
    }

    void object() {
        const bool has_upload = target_.query.count("uploadId") != 0;
        switch (req_.method()) {
        case http::verb::get:
        case http::verb::head:
            if (has_upload || target_.query.count("partNumber") != 0) {
                return not_implemented("Reading single parts");
            }
            if (target_.query.count("acl") != 0 || target_.query.count("tagging") != 0) {
                return not_implemented("This object subresource");
            }
            return get_object();
        case http::verb::put:
            if (req_.find("x-amz-copy-source") != req_.end()) {
                return not_implemented("CopyObject");
            }
            return put_object();
        case http::verb::delete_:
            if (has_upload) {
                const StoreError error = store_.abort_upload(query_value("uploadId"));
                if (error != StoreError::none) {
                    return respond_.store_error(error, target_.bucket);
                }
                return respond_.empty(http::status::no_content);
            }
            if (const StoreError error = store_.remove(target_.bucket, target_.key);
                error != StoreError::none) {
                return respond_.store_error(error, target_.bucket);
            }
            return respond_.empty(http::status::no_content);
        case http::verb::post:
            if (target_.query.count("uploads") != 0) {
                return create_upload();
            }
            if (has_upload) {
                return complete_upload();
            }
            return not_implemented("This object POST");
        default:
            respond_.error(http::status::method_not_allowed, "MethodNotAllowed", "Unsupported method");
        }
    }

    void get_object() {
        ObjectPtr object = store_.get(target_.bucket, target_.key);
        if (!object) {
            if (!store_.bucket_exists(target_.bucket)) {
                return respond_.store_error(StoreError::no_such_bucket, target_.bucket);
            }
            return respond_.store_error(StoreError::no_such_key, target_.bucket);
        }

        ByteRange         range{0, object->size() == 0 ? 0 : object->size() - 1};
        const RangeResult range_result = parse_range(header(req_, "range"), object->size(), range);
        if (range_result == RangeResult::invalid) {
            http::response<http::string_body> res{http::status::range_not_satisfiable, req_.version()};
            res.set(http::field::content_range, "bytes */" + std::to_string(object->size()));
            res.set(http::field::content_type, "application/xml");
            res.body() = std::string(XML_DECLARATION) +
                         "<Error><Code>InvalidRange</Code><Message>The requested range is not "
                         "satisfiable</Message></Error>";
            res.prepare_payload();
            return respond_.send(res);
        }
        const bool     partial = range_result == RangeResult::valid;
        const uint64_t length  = object->size() == 0 ? 0 : range.last - range.first + 1;
        const auto     status  = partial ? http::status::partial_content : http::status::ok;
        const uint8_t *data    = object->data() + range.first;

        const auto set_common = [&](http::response_header<> &res) {
            set_object_headers(res, *object);
            if (partial) {
                res.set(http::field::content_range, "bytes " + std::to_string(range.first) + "-" +
                                                        std::to_string(range.last) + "/" +
                                                        std::to_string(object->size()));
            }
        };

        if (req_.method() == http::verb::head) {
            http::response<http::empty_body> res{status, req_.version()};
            set_common(res.base());
            res.content_length(length);
            return respond_.send(res);
        }

        bool       refused = false;
        const auto token   = usable_token(refused);
        if (refused) {
            return;
        }
        if (token) {
            // A larger buffer than the object is fine. A smaller one does not fit, which is a client
            // bug rather than a reason to decline.
            if (token->length < length) {
                return respond_.error(http::status::bad_request, "InvalidArgument",
                                      "The token's buffer is smaller than the requested bytes");
            }
            const TransferStatus result = engine_->write(*token, data, length);
            if (result == TransferStatus::no_session) {
                return decline_rdma("The token names an unknown QP. Connect it at /rdma/connect first");
            }
            if (result == TransferStatus::failed) {
                return respond_.error(http::status::service_unavailable, "RDMATransferError",
                                      "The RDMA transfer failed. Reconnect, or retry without the token");
            }
            http::response<http::empty_body> res{status, req_.version()};
            set_common(res.base());
            res.set(RDMA_REPLY_HEADER, partial ? "206" : "200");
            res.set(RDMA_BYTES_HEADER, std::to_string(length));
            res.content_length(0);
            return respond_.send(res);
        }

        http::response<http::span_body<const char>> res{status, req_.version()};
        set_common(res.base());
        res.body() = boost::beast::span<const char>(reinterpret_cast<const char *>(data), length);
        res.prepare_payload();
        respond_.send(res);
    }

    // Fills a new object from the token or the HTTP body. On failure the response has been sent.
    ObjectPtr receive_object() {
        bool       refused = false;
        const auto token   = usable_token(refused);
        if (refused) {
            return nullptr;
        }

        ObjectPtr object;
        if (token) {
            object = store_.allocate(token->length);
            if (!object) {
                respond_.store_error(StoreError::out_of_space, target_.bucket);
                return nullptr;
            }
            const TransferStatus result = engine_->read(*token, object->data(), token->length);
            if (result == TransferStatus::no_session) {
                decline_rdma("The token names an unknown QP. Connect it at /rdma/connect first");
                return nullptr;
            }
            if (result == TransferStatus::failed) {
                respond_.error(http::status::service_unavailable, "RDMATransferError",
                               "The RDMA transfer failed. Reconnect, or retry without the token");
                return nullptr;
            }
        } else {
            std::string        decoded;
            const std::string *body = &req_.body();
            if (is_aws_chunked(req_)) {
                if (!decode_aws_chunked(req_.body(), decoded)) {
                    respond_.error(http::status::bad_request, "IncompleteBody", "Malformed aws-chunked body");
                    return nullptr;
                }
                body = &decoded;
            }
            object = store_.allocate(body->size());
            if (!object) {
                respond_.store_error(StoreError::out_of_space, target_.bucket);
                return nullptr;
            }
            std::memcpy(object->data(), body->data(), body->size());
        }

        object->etag          = md5_hex(object->data(), object->size());
        object->last_modified = std::time(nullptr);
        if (const std::string type = header(req_, "content-type"); !type.empty()) {
            object->content_type = type;
        }
        return object;
    }

    void put_object() {
        const bool has_upload = target_.query.count("uploadId") != 0;
        int        part       = 0;
        if (has_upload) {
            try {
                part = std::stoi(query_value("partNumber"));
            } catch (const std::exception &) {
                part = 0;
            }
            if (part < 1 || part > MAX_PART_NUMBER) {
                return respond_.error(http::status::bad_request, "InvalidArgument", "Invalid partNumber");
            }
        } else if (!target_.query.empty()) {
            return not_implemented("This object subresource");
        }
        if (!store_.bucket_exists(target_.bucket)) {
            return respond_.store_error(StoreError::no_such_bucket, target_.bucket);
        }

        ObjectPtr object = receive_object();
        if (!object) {
            return;
        }
        const std::string etag = quoted(object->etag);

        const bool       used_rdma = req_.find(RDMA_TOKEN_HEADER) != req_.end();
        const uint64_t   size      = object->size();
        const StoreError error =
            has_upload ? store_.put_part(query_value("uploadId"), part, std::move(object))
                       : store_.put(target_.bucket, target_.key, std::move(object));
        if (error != StoreError::none) {
            return respond_.store_error(error, target_.bucket);
        }

        http::response<http::empty_body> res{http::status::ok, req_.version()};
        res.set(http::field::etag, etag);
        if (used_rdma) {
            res.set(RDMA_REPLY_HEADER, "200");
            res.set(RDMA_BYTES_HEADER, std::to_string(size));
        }
        res.content_length(0);
        respond_.send(res);
    }

    void create_upload() {
        if (!store_.bucket_exists(target_.bucket)) {
            return respond_.store_error(StoreError::no_such_bucket, target_.bucket);
        }
        const std::string  id = store_.create_upload(target_.bucket, target_.key);
        std::ostringstream xml;
        xml << XML_DECLARATION << "<InitiateMultipartUploadResult xmlns=\"" << XML_NAMESPACE
            << "\"><Bucket>" << xml_escape(target_.bucket) << "</Bucket><Key>" << xml_escape(target_.key)
            << "</Key><UploadId>" << id << "</UploadId></InitiateMultipartUploadResult>";
        respond_.xml(http::status::ok, xml.str());
    }

    void complete_upload() {
        const auto numbers = xml_values(req_.body(), "PartNumber");
        const auto etags   = xml_values(req_.body(), "ETag");
        if (numbers.empty() || numbers.size() != etags.size()) {
            return respond_.error(http::status::bad_request, "MalformedXML", "Invalid part list");
        }
        std::vector<UploadedPart> parts;
        parts.reserve(numbers.size());
        try {
            for (size_t i = 0; i < numbers.size(); ++i) {
                parts.push_back(UploadedPart{std::stoi(numbers[i]), etags[i]});
            }
        } catch (const std::exception &) {
            return respond_.error(http::status::bad_request, "MalformedXML", "Invalid part number");
        }

        ObjectPtr        completed;
        const StoreError error = store_.complete_upload(query_value("uploadId"), parts, completed);
        if (error != StoreError::none) {
            return respond_.store_error(error, target_.bucket);
        }
        const std::string etag = quoted(completed->etag);
        if (const StoreError put_error = store_.put(target_.bucket, target_.key, std::move(completed));
            put_error != StoreError::none) {
            return respond_.store_error(put_error, target_.bucket);
        }

        std::ostringstream xml;
        xml << XML_DECLARATION << "<CompleteMultipartUploadResult xmlns=\"" << XML_NAMESPACE
            << "\"><Bucket>" << xml_escape(target_.bucket) << "</Bucket><Key>" << xml_escape(target_.key)
            << "</Key><ETag>" << xml_escape(etag) << "</ETag></CompleteMultipartUploadResult>";
        respond_.xml(http::status::ok, xml.str());
    }

    ObjectStore  &store_;
    RdmaEngine   *engine_;
    const Request &req_;
    Target        target_;
    Responder     respond_;
};

} // namespace

void S3Server::serve_connection(int fd, Connection &connection) {
    struct DoneGuard {
        Connection &connection;
        ~DoneGuard() { connection.done.store(true); }
    } done_guard{connection};

    asio::io_context io;
    tcp::socket      socket(io);
    beast::error_code ec;
    socket.assign(tcp::v4(), fd, ec);
    if (ec) {
        close(fd);
        return;
    }
    socket.set_option(tcp::no_delay(true), ec);

    // Kept across requests: pipelined requests that arrived together sit in here.
    beast::flat_buffer buffer;
    while (true) {
        http::request_parser<http::string_body> parser;
        parser.header_limit(MAX_HEADER_BYTES);
        parser.body_limit(body_limit_);

        http::read_header(socket, buffer, parser, ec);
        if (ec) {
            break;
        }
        if (beast::iequals(parser.get()[http::field::expect], "100-continue")) {
            http::response<http::empty_body> proceed{http::status::continue_, parser.get().version()};
            http::write(socket, proceed, ec);
            if (ec) {
                break;
            }
        }
        http::read(socket, buffer, parser, ec);
        if (ec) {
            break;
        }

        const Request &request = parser.get();
        Handler        handler(store_, engine_, request, socket);
        if (!handler.run() || !request.keep_alive()) {
            break;
        }
    }
    socket.shutdown(tcp::socket::shutdown_both, ec);
}

bool S3Server::run(const std::string &address, uint16_t port, const std::atomic<bool> &stop) {
    const int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) {
        std::cerr << "Could not create socket\n";
        return false;
    }
    int optval = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(optval));

    sockaddr_in server = {};
    server.sin_family  = AF_INET;
    server.sin_port    = htons(port);
    if (inet_pton(AF_INET, address.c_str(), &server.sin_addr) != 1) {
        std::cerr << "Invalid listen address " << address << "\n";
        close(listen_fd);
        return false;
    }
    if (bind(listen_fd, reinterpret_cast<sockaddr *>(&server), sizeof(server)) < 0 ||
        listen(listen_fd, BACKLOG) < 0) {
        std::cerr << "Could not listen on " << address << ":" << port << ": " << strerror(errno) << "\n";
        close(listen_fd);
        return false;
    }

    std::list<Connection> connections;
    const auto            reap = [&connections] {
        for (auto it = connections.begin(); it != connections.end();) {
            if (it->done.load()) {
                it->thread.join();
                it = connections.erase(it);
            } else {
                ++it;
            }
        }
    };

    while (!stop.load()) {
        reap();

        pollfd pfd = {};
        pfd.fd     = listen_fd;
        pfd.events = POLLIN;
        if (poll(&pfd, 1, 200 /* ms */) <= 0) {
            continue; // Timeout or EINTR: the loop re-checks `stop`.
        }
        const int fd = accept(listen_fd, nullptr, nullptr);
        if (fd < 0) {
            continue;
        }
        if (connections.size() >= MAX_CONNECTIONS) {
            std::cerr << "At the limit of " << MAX_CONNECTIONS << " connections, rejecting one\n";
            close(fd);
            continue;
        }
        connections.emplace_back();
        Connection &connection = connections.back();
        connection.fd          = fd;
        connection.thread      = std::thread([this, fd, &connection] { serve_connection(fd, connection); });
    }

    close(listen_fd);
    // Blocked reads wake up once their socket is shut down.
    for (auto &connection : connections) {
        if (!connection.done.load()) {
            shutdown(connection.fd, SHUT_RDWR);
        }
        connection.thread.join();
    }
    return true;
}

} // namespace oasis_s3
