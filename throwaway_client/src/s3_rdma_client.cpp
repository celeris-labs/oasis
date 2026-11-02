#include "s3_rdma_client.hpp"

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstring>
#include <fstream>
#include <netdb.h>
#include <netinet/tcp.h>
#include <sstream>
#include <stdexcept>
#include <sys/socket.h>
#include <unistd.h>

namespace oasis_s3 {

namespace {

constexpr uint32_t INITIAL_PSN = 0; // Tokens have no PSN field, so both sides start at zero.

bool IsRocev2Ipv4(ibv_context *context, int port, int index, ibv_gid &gid) {
	if (ibv_query_gid(context, static_cast<uint8_t>(port), index, &gid) != 0) {
		return false;
	}
	static const uint8_t v4_prefix[12] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff};
	if (std::memcmp(gid.raw, v4_prefix, sizeof(v4_prefix)) != 0) {
		return false;
	}
	std::ostringstream path;
	path << "/sys/class/infiniband/" << ibv_get_device_name(context->device) << "/ports/" << port
	     << "/gid_attrs/types/" << index;
	std::ifstream file(path.str());
	std::string type;
	std::getline(file, type);
	return type == "RoCE v2";
}

} // namespace

RdmaDevice::RdmaDevice(int device_index) {
	int num_devices = 0;
	ibv_device **devices = ibv_get_device_list(&num_devices);
	if (!devices || device_index >= num_devices) {
		if (devices) {
			ibv_free_device_list(devices);
		}
		throw std::runtime_error("RDMA device not found");
	}
	context = ibv_open_device(devices[device_index]);
	ibv_free_device_list(devices);
	if (!context) {
		throw std::runtime_error("Could not open RDMA device");
	}
	pd = ibv_alloc_pd(context);
	if (!pd) {
		throw std::runtime_error("Could not allocate protection domain");
	}

	ibv_port_attr port_attr = {};
	if (ibv_query_port(context, static_cast<uint8_t>(ib_port), &port_attr) != 0) {
		throw std::runtime_error("Could not query RDMA port");
	}
	path_mtu = std::min(port_attr.active_mtu, IBV_MTU_4096);
	for (int i = 0; i < port_attr.gid_tbl_len && gid_index < 0; ++i) {
		if (IsRocev2Ipv4(context, ib_port, i, gid)) {
			gid_index = i;
		}
	}
	if (gid_index < 0) {
		throw std::runtime_error("No RoCE v2 IPv4 GID found");
	}
}

RdmaDevice::~RdmaDevice() {
	if (pd) {
		ibv_dealloc_pd(pd);
	}
	if (context) {
		ibv_close_device(context);
	}
}

std::string HttpResponse::header(const std::string &name) const {
	auto it = headers.find(name);
	return it == headers.end() ? std::string() : it->second;
}

HttpConnection::HttpConnection(std::string host, uint16_t port) : host_(std::move(host)), port_(port) {
	addrinfo hints = {};
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_STREAM;
	addrinfo *result = nullptr;
	const std::string service = std::to_string(port_);
	if (getaddrinfo(host_.c_str(), service.c_str(), &hints, &result) != 0) {
		throw std::runtime_error("Could not resolve " + host_);
	}
	fd_ = socket(result->ai_family, result->ai_socktype, result->ai_protocol);
	if (fd_ < 0 || connect(fd_, result->ai_addr, result->ai_addrlen) != 0) {
		const std::string reason = strerror(errno);
		freeaddrinfo(result);
		throw std::runtime_error("Could not connect to " + host_ + ":" + service + ": " + reason);
	}
	freeaddrinfo(result);
	const int one = 1;
	setsockopt(fd_, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
}

HttpConnection::~HttpConnection() {
	if (fd_ >= 0) {
		close(fd_);
	}
}

HttpResponse HttpConnection::request(const std::string &method, const std::string &target,
                                     const std::vector<std::pair<std::string, std::string>> &headers) {
	std::ostringstream head;
	head << method << " " << target << " HTTP/1.1\r\nHost: " << host_ << ":" << port_ << "\r\n";
	for (const auto &entry : headers) {
		head << entry.first << ": " << entry.second << "\r\n";
	}
	if (method == "POST") {
		head << "Content-Length: 0\r\n";
	}
	head << "\r\n";
	const std::string text = head.str();
	for (size_t sent = 0; sent < text.size();) {
		const ssize_t count = ::send(fd_, text.data() + sent, text.size() - sent, MSG_NOSIGNAL);
		if (count <= 0) {
			throw std::runtime_error(std::string("HTTP send failed: ") + strerror(errno));
		}
		sent += static_cast<size_t>(count);
	}

	const auto fill = [this] {
		char chunk[64 * 1024];
		const ssize_t got = ::recv(fd_, chunk, sizeof(chunk), 0);
		if (got <= 0) {
			throw std::runtime_error("The server closed the HTTP connection");
		}
		buffer_.append(chunk, static_cast<size_t>(got));
	};

	size_t header_end;
	while ((header_end = buffer_.find("\r\n\r\n")) == std::string::npos) {
		fill();
	}

	HttpResponse response;
	std::istringstream lines(buffer_.substr(0, header_end));
	std::string line;
	std::getline(lines, line);
	std::istringstream status_line(line);
	std::string version;
	status_line >> version >> response.status;
	while (std::getline(lines, line)) {
		if (!line.empty() && line.back() == '\r') {
			line.pop_back();
		}
		const size_t colon = line.find(':');
		if (colon == std::string::npos) {
			continue;
		}
		std::string name = line.substr(0, colon);
		std::transform(name.begin(), name.end(), name.begin(),
		               [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
		size_t value = colon + 1;
		while (value < line.size() && line[value] == ' ') {
			++value;
		}
		response.headers[name] = line.substr(value);
	}
	buffer_.erase(0, header_end + 4);

	if (method != "HEAD") {
		const std::string length_text = response.header("content-length");
		const uint64_t length = length_text.empty() ? 0 : std::stoull(length_text);
		while (buffer_.size() < length) {
			fill();
		}
		response.body = buffer_.substr(0, length);
		buffer_.erase(0, length);
	}
	return response;
}

RdmaConnection::RdmaConnection(RdmaDevice &device, const std::string &host, uint16_t port)
    : device_(device), http_(host, port) {
	Connect();
}

RdmaConnection::~RdmaConnection() {
	if (qp_) {
		ibv_destroy_qp(qp_);
	}
	if (cq_) {
		ibv_destroy_cq(cq_);
	}
}

void RdmaConnection::Connect() {
	cq_ = ibv_create_cq(device_.context, 16, nullptr, nullptr, 0);
	if (!cq_) {
		throw std::runtime_error("Could not create completion queue");
	}

	// The server initiates everything, so this QP never posts a work request and only responds.
	ibv_qp_init_attr init_attr = {};
	init_attr.send_cq = cq_;
	init_attr.recv_cq = cq_;
	init_attr.qp_type = IBV_QPT_RC;
	init_attr.cap.max_send_wr = 1;
	init_attr.cap.max_recv_wr = 1;
	init_attr.cap.max_send_sge = 1;
	init_attr.cap.max_recv_sge = 1;
	qp_ = ibv_create_qp(device_.pd, &init_attr);
	if (!qp_) {
		throw std::runtime_error(std::string("Could not create queue pair: ") + strerror(errno));
	}

	ibv_qp_attr attr = {};
	attr.qp_state = IBV_QPS_INIT;
	attr.port_num = static_cast<uint8_t>(device_.ib_port);
	attr.qp_access_flags = IBV_ACCESS_REMOTE_WRITE;
	int ret = ibv_modify_qp(qp_, &attr, IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | IBV_QP_ACCESS_FLAGS);
	if (ret) {
		throw std::runtime_error(std::string("Could not move QP to INIT: ") + strerror(ret));
	}

	RdmaToken local;
	local.qpn = qp_->qp_num;
	local.gid_present = true;
	std::memcpy(local.gid.data(), device_.gid.raw, local.gid.size());

	const HttpResponse reply = http_.request("POST", RDMA_CONNECT_PATH, {{RDMA_TOKEN_HEADER, format_token(local)}});
	const std::string text = reply.header(RDMA_REPLY_HEADER);
	if (reply.status != 200 || text.rfind("200:", 0) != 0) {
		throw std::runtime_error("RDMA connect was declined: HTTP " + std::to_string(reply.status));
	}
	const auto peer = parse_token(std::string_view(text).substr(4));
	if (!peer) {
		throw std::runtime_error("RDMA connect returned a malformed token: " + text);
	}

	attr = {};
	attr.qp_state = IBV_QPS_RTR;
	attr.path_mtu = device_.path_mtu;
	attr.dest_qp_num = peer->qpn;
	attr.rq_psn = INITIAL_PSN;
	attr.max_dest_rd_atomic = 1;
	attr.min_rnr_timer = 12;
	attr.ah_attr.is_global = 1;
	attr.ah_attr.dlid = peer->lid;
	attr.ah_attr.port_num = static_cast<uint8_t>(device_.ib_port);
	attr.ah_attr.grh.hop_limit = 64;
	attr.ah_attr.grh.sgid_index = static_cast<uint8_t>(device_.gid_index);
	std::memcpy(attr.ah_attr.grh.dgid.raw, peer->gid.data(), peer->gid.size());
	ret = ibv_modify_qp(qp_, &attr,
	                    IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN | IBV_QP_RQ_PSN |
	                        IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER);
	if (ret) {
		throw std::runtime_error(std::string("Could not move QP to RTR: ") + strerror(ret));
	}

	attr = {};
	attr.qp_state = IBV_QPS_RTS;
	attr.sq_psn = INITIAL_PSN;
	attr.timeout = 14;
	attr.retry_cnt = 7;
	attr.rnr_retry = 7;
	attr.max_rd_atomic = 1;
	ret = ibv_modify_qp(qp_, &attr,
	                    IBV_QP_STATE | IBV_QP_SQ_PSN | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY |
	                        IBV_QP_MAX_QP_RD_ATOMIC);
	if (ret) {
		throw std::runtime_error(std::string("Could not move QP to RTS: ") + strerror(ret));
	}
}

void RdmaConnection::read(const std::string &target, uint64_t offset, uint64_t size, uint8_t *dst,
                          const std::string &expected_etag) {
	if (size > RDMA_TOKEN_MAX_LENGTH) {
		throw std::runtime_error("A read of " + std::to_string(size) + " bytes does not fit in one RDMA token");
	}

	ibv_mr *mr = ibv_reg_mr(device_.pd, dst, size, IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE);
	if (!mr) {
		throw std::runtime_error(std::string("Could not register the read buffer: ") + strerror(errno));
	}
	struct Deregister {
		ibv_mr *mr;
		~Deregister() {
			ibv_dereg_mr(mr);
		}
	} deregister {mr};

	RdmaToken token;
	token.qpn = qp_->qp_num;
	token.gid_present = true;
	std::memcpy(token.gid.data(), device_.gid.raw, token.gid.size());
	token.rkey = mr->rkey;
	token.addr = reinterpret_cast<uint64_t>(dst);
	token.length = static_cast<uint32_t>(size);

	const HttpResponse response = http_.request(
	    "GET", target,
	    {{"Range", "bytes=" + std::to_string(offset) + "-" + std::to_string(offset + size - 1)},
	     {RDMA_TOKEN_HEADER, format_token(token)}});
	if (response.status != 206) {
		throw std::runtime_error("Ranged GET failed: HTTP " + std::to_string(response.status) + " " + response.body);
	}
	if (response.header(RDMA_REPLY_HEADER) != "206") {
		throw std::runtime_error("The server did not use RDMA (reply '" + response.header(RDMA_REPLY_HEADER) + "')");
	}
	const std::string transferred = response.header(RDMA_BYTES_HEADER);
	if (transferred.empty() || std::stoull(transferred) != size) {
		throw std::runtime_error("RDMA short transfer: expected " + std::to_string(size) +
		                         " bytes, the server reports '" + transferred + "'");
	}
	if (response.header("etag") != expected_etag) {
		throw std::runtime_error("The object changed during the read (ETag mismatch)");
	}
}

} // namespace oasis_s3
