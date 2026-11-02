// THROWAWAY: a software S3-over-RDMA client, to exercise oasis_s3_server before Oasis integrates with
// it. It serves s3:// by having the server write column bytes straight into DuckDB's read buffers,
// and DuckDB's own Parquet reader decodes them on the CPU.
#define DUCKDB_EXTENSION_MAIN

#include "oasis_sw_extension.hpp"
#include "s3_rdma_client.hpp"

#include "duckdb.hpp"
#include "duckdb/common/exception.hpp"
#include "duckdb/common/file_opener.hpp"
#include "duckdb/common/file_system.hpp"
#include "duckdb/common/types/timestamp.hpp"
#include "duckdb/function/scalar/string_common.hpp"
#include "duckdb/main/config.hpp"
#include "duckdb/main/database.hpp"
#include "duckdb/main/extension/extension_loader.hpp"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <ctime>
#include <memory>
#include <mutex>
#include <vector>

namespace duckdb {

namespace {

constexpr const char *S3_PREFIX = "s3://";

struct ClientConfig {
	std::string host;
	uint16_t port = 0;
	int device = 0;
};

ClientConfig ReadConfig(optional_ptr<FileOpener> opener) {
	Value value;
	if (!FileOpener::TryGetCurrentSetting(opener, "oasis_sw_endpoint", value) || value.IsNull()) {
		throw InvalidConfigurationException("s3:// needs a server: SET oasis_sw_endpoint = '<host>:<port>';");
	}
	const auto endpoint = value.ToString();
	const auto colon = endpoint.rfind(':');
	if (colon == std::string::npos) {
		throw InvalidConfigurationException("oasis_sw_endpoint must be '<host>:<port>', got '%s'", endpoint);
	}

	ClientConfig config;
	config.host = endpoint.substr(0, colon);
	config.port = static_cast<uint16_t>(std::stoi(endpoint.substr(colon + 1)));
	if (FileOpener::TryGetCurrentSetting(opener, "oasis_sw_device", value) && !value.IsNull()) {
		config.device = static_cast<int>(value.GetValue<uint64_t>());
	}
	return config;
}

// "/bucket/key" with everything that is not safe in a request target percent-encoded.
std::string EncodeTarget(const std::string &path) {
	static const char *digits = "0123456789ABCDEF";
	std::string out = "/";
	for (unsigned char c : path) {
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

std::string EncodeQueryValue(const std::string &text) {
	static const char *digits = "0123456789ABCDEF";
	std::string out;
	for (unsigned char c : text) {
		if (std::isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
			out.push_back(static_cast<char>(c));
		} else {
			out.push_back('%');
			out.push_back(digits[c >> 4]);
			out.push_back(digits[c & 0xf]);
		}
	}
	return out;
}

std::string XmlUnescape(std::string text) {
	static const std::pair<const char *, const char *> entities[] = {
	    {"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", "\""}, {"&apos;", "'"}, {"&amp;", "&"}};
	for (const auto &entity : entities) {
		size_t pos = 0;
		while ((pos = text.find(entity.first, pos)) != std::string::npos) {
			text.replace(pos, std::strlen(entity.first), entity.second);
			pos += std::strlen(entity.second);
		}
	}
	return text;
}

std::vector<std::string> XmlValues(const std::string &xml, const std::string &tag) {
	std::vector<std::string> values;
	const std::string open = "<" + tag + ">";
	const std::string close = "</" + tag + ">";
	size_t pos = 0;
	while ((pos = xml.find(open, pos)) != std::string::npos) {
		const size_t begin = pos + open.size();
		const size_t end = xml.find(close, begin);
		if (end == std::string::npos) {
			break;
		}
		values.push_back(XmlUnescape(xml.substr(begin, end - begin)));
		pos = end + close.size();
	}
	return values;
}

// Reuses connections between reads: setting one up takes a QP and an HTTP round trip. There is one for
// every read running at the same time, so never more than DuckDB has threads.
class ConnectionPool {
public:
	std::unique_ptr<oasis_s3::RdmaConnection> Acquire(const ClientConfig &config) {
		std::lock_guard<std::mutex> lock(mtx_);
		if (!device_ || device_index_ != config.device) {
			idle_.clear();
			device_ = std::make_unique<oasis_s3::RdmaDevice>(config.device);
			device_index_ = config.device;
		}
		for (auto it = idle_.begin(); it != idle_.end(); ++it) {
			if (it->host == config.host && it->port == config.port) {
				auto connection = std::move(it->connection);
				idle_.erase(it);
				return connection;
			}
		}
		return std::make_unique<oasis_s3::RdmaConnection>(*device_, config.host, config.port);
	}

	void Release(const ClientConfig &config, std::unique_ptr<oasis_s3::RdmaConnection> connection) {
		std::lock_guard<std::mutex> lock(mtx_);
		idle_.push_back(Idle {config.host, config.port, std::move(connection)});
	}

private:
	struct Idle {
		std::string host;
		uint16_t port;
		std::unique_ptr<oasis_s3::RdmaConnection> connection;
	};

	std::mutex mtx_;
	std::unique_ptr<oasis_s3::RdmaDevice> device_;
	int device_index_ = -1;
	std::vector<Idle> idle_;
};

struct ObjectInfo {
	uint64_t size = 0;
	std::string etag;
	std::string last_modified;
};

class OasisSwFileHandle : public FileHandle {
public:
	OasisSwFileHandle(FileSystem &fs, string path, FileOpenFlags flags, std::string target, ClientConfig config,
	                  ObjectInfo info)
	    : FileHandle(fs, std::move(path), flags), target(std::move(target)), config(std::move(config)),
	      info(std::move(info)) {
	}

	void Close() override {
	}

	std::string target;
	ClientConfig config;
	ObjectInfo info;
	uint64_t cursor = 0;
};

class OasisSwFileSystem : public FileSystem {
public:
	std::string GetName() const override {
		return "OasisSwFileSystem";
	}

	bool CanHandleFile(const string &path) override {
		return path.rfind(S3_PREFIX, 0) == 0;
	}

	// Wins over httpfs regardless of the load order.
	bool IsManuallySet() override {
		return true;
	}

	bool CanSeek() override {
		return true;
	}

	bool OnDiskFile(FileHandle &) override {
		return false;
	}

	unique_ptr<FileHandle> OpenFile(const string &path, FileOpenFlags flags, optional_ptr<FileOpener> opener) override {
		if (flags.OpenForWriting()) {
			throw IOException("The throwaway s3:// client is read-only");
		}
		auto config = ReadConfig(opener);
		auto target = EncodeTarget(path.substr(std::strlen(S3_PREFIX)));
		oasis_s3::HttpResponse head;
		try {
			head = ControlRequest(config, "HEAD", target);
		} catch (const std::exception &error) {
			throw IOException("HEAD %s failed: %s", path, error.what());
		}
		if (head.status == 404) {
			if (flags.ReturnNullIfNotExists()) {
				return nullptr;
			}
			throw IOException("No object at %s", path);
		}
		if (head.status != 200) {
			throw IOException("HEAD %s returned HTTP %d", path, head.status);
		}
		ObjectInfo info;
		info.size = std::stoull(head.header("content-length"));
		info.etag = head.header("etag");
		info.last_modified = head.header("last-modified");
		return make_uniq<OasisSwFileHandle>(*this, path, flags, std::move(target), std::move(config), std::move(info));
	}

	bool FileExists(const string &path, optional_ptr<FileOpener> opener) override {
		auto config = ReadConfig(opener);
		return ControlRequest(config, "HEAD", EncodeTarget(path.substr(std::strlen(S3_PREFIX)))).status == 200;
	}

	vector<OpenFileInfo> Glob(const string &path, FileOpener *opener) override {
		if (!HasGlob(path)) {
			if (FileExists(path, opener)) {
				return {OpenFileInfo(path)};
			}
			return {};
		}
		auto config = ReadConfig(opener);
		const std::string rest = path.substr(std::strlen(S3_PREFIX));
		const size_t slash = rest.find('/');
		if (slash == std::string::npos) {
			throw IOException("Cannot glob over buckets: %s", path);
		}
		const std::string bucket = rest.substr(0, slash);
		const std::string pattern = rest.substr(slash + 1);
		const std::string prefix = pattern.substr(0, pattern.find_first_of("*?["));

		vector<OpenFileInfo> result;
		std::string token;
		do {
			std::string target =
			    "/" + bucket + "?list-type=2&prefix=" + EncodeQueryValue(prefix);
			if (!token.empty()) {
				target += "&continuation-token=" + EncodeQueryValue(token);
			}
			const auto listing = ControlRequest(config, "GET", target);
			// A bucket that does not exist matches nothing, like a pattern that does not match.
			if (listing.status == 404) {
				return {};
			}
			if (listing.status != 200) {
				throw IOException("Listing %s returned HTTP %d", path, listing.status);
			}
			for (const auto &key : XmlValues(listing.body, "Key")) {
				if (duckdb::Glob(key.c_str(), key.size(), pattern.c_str(), pattern.size())) {
					result.emplace_back(std::string(S3_PREFIX) + bucket + "/" + key);
				}
			}
			const auto next = XmlValues(listing.body, "NextContinuationToken");
			token = next.empty() ? "" : next.front();
		} while (!token.empty());
		std::sort(result.begin(), result.end());
		return result;
	}

	void Read(FileHandle &handle, void *buffer, int64_t nr_bytes, idx_t location) override {
		auto &file = handle.Cast<OasisSwFileHandle>();
		if (nr_bytes < 0 || location + static_cast<uint64_t>(nr_bytes) > file.info.size) {
			throw IOException("Read past the end of %s", handle.path);
		}
		ReadBytes(file, static_cast<uint8_t *>(buffer), static_cast<uint64_t>(nr_bytes), location);
	}

	int64_t Read(FileHandle &handle, void *buffer, int64_t nr_bytes) override {
		auto &file = handle.Cast<OasisSwFileHandle>();
		if (nr_bytes < 0) {
			throw IOException("Negative read size on %s", handle.path);
		}
		const uint64_t remaining = file.info.size > file.cursor ? file.info.size - file.cursor : 0;
		const uint64_t size = std::min<uint64_t>(static_cast<uint64_t>(nr_bytes), remaining);
		ReadBytes(file, static_cast<uint8_t *>(buffer), size, file.cursor);
		file.cursor += size;
		return static_cast<int64_t>(size);
	}

	void Seek(FileHandle &handle, idx_t location) override {
		auto &file = handle.Cast<OasisSwFileHandle>();
		if (location > file.info.size) {
			throw IOException("Seek past the end of %s", handle.path);
		}
		file.cursor = location;
	}

	idx_t SeekPosition(FileHandle &handle) override {
		return handle.Cast<OasisSwFileHandle>().cursor;
	}

	int64_t GetFileSize(FileHandle &handle) override {
		return static_cast<int64_t>(handle.Cast<OasisSwFileHandle>().info.size);
	}

	timestamp_t GetLastModifiedTime(FileHandle &handle) override {
		std::tm parsed = {};
		const auto &text = handle.Cast<OasisSwFileHandle>().info.last_modified;
		if (!strptime(text.c_str(), "%a, %d %b %Y %H:%M:%S GMT", &parsed)) {
			return timestamp_t(0);
		}
		return Timestamp::FromEpochSeconds(timegm(&parsed));
	}

	string GetVersionTag(FileHandle &handle) override {
		return handle.Cast<OasisSwFileHandle>().info.etag;
	}

private:
	void ReadBytes(OasisSwFileHandle &file, uint8_t *dst, uint64_t size, uint64_t location) {
		if (size == 0) {
			return;
		}
		try {
			auto connection = pool_.Acquire(file.config);
			connection->read(file.target, location, size, dst, file.info.etag);
			// Not on failure: a QP that saw an error does not recover, so that connection just closes.
			pool_.Release(file.config, std::move(connection));
		} catch (const std::exception &error) {
			throw IOException("Reading %s failed: %s", file.path, error.what());
		}
	}

	oasis_s3::HttpResponse ControlRequest(const ClientConfig &config, const std::string &method,
	                                      const std::string &target) {
		std::lock_guard<std::mutex> lock(control_mtx_);
		for (int attempt = 0;; ++attempt) {
			try {
				if (!control_ || control_host_ != config.host || control_port_ != config.port) {
					control_ = std::make_unique<oasis_s3::HttpConnection>(config.host, config.port);
					control_host_ = config.host;
					control_port_ = config.port;
				}
				return control_->request(method, target);
			} catch (const std::exception &) {
				// The server may have closed an idle keep-alive connection. Try once on a fresh one.
				control_.reset();
				if (attempt > 0) {
					throw;
				}
			}
		}
	}

	ConnectionPool pool_;
	std::mutex control_mtx_;
	std::unique_ptr<oasis_s3::HttpConnection> control_;
	std::string control_host_;
	uint16_t control_port_ = 0;
};

void LoadInternal(ExtensionLoader &loader) {
	auto &instance = loader.GetDatabaseInstance();
	auto &config = DBConfig::GetConfig(instance);

	config.AddExtensionOption("oasis_sw_endpoint", "oasis_s3_server to read s3:// from, as '<host>:<port>'",
	                          LogicalType::VARCHAR, Value(LogicalType::VARCHAR));
	config.AddExtensionOption("oasis_sw_device", "RDMA device index", LogicalType::UBIGINT, Value::UBIGINT(0));
	FileSystem::GetFileSystem(instance).RegisterSubSystem(make_uniq<OasisSwFileSystem>());
}

} // namespace

void OasisSwExtension::Load(ExtensionLoader &loader) {
	LoadInternal(loader);
}

std::string OasisSwExtension::Name() {
	return "oasis_sw";
}

std::string OasisSwExtension::Version() const {
	return "throwaway";
}

} // namespace duckdb

extern "C" {
DUCKDB_CPP_EXTENSION_ENTRY(oasis_sw, loader) {
	duckdb::LoadInternal(loader);
}
}
