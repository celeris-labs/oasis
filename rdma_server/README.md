# Oasis S3 Server

An S3-compatible object server that moves payload over RDMA. Control is ordinary S3 over HTTP. A
request with an `x-amz-rdma-token` header has its payload moved by the server: an RDMA WRITE for
`GetObject`, an RDMA READ for `PutObject` and `UploadPart`. Stock S3 clients send no token and get the
payload in the HTTP body. Objects live in one memory region, so nothing survives a restart.

## Build

```bash
cmake -S . -B build -G Ninja
cmake --build build
```

## Run

```bash
./build/oasis_s3_server --capacity 64G --preload tpch=/data/parquet/
aws --endpoint-url http://127.0.0.1:9000 s3 ls s3://tpch/
```

`--preload BUCKET=PATH` loads a file, or every file of a directory, at startup. See `--help` for the
other options.

## RDMA protocol

Tokens are the 81-character cuObject descriptor, so one token covers at most 4 GiB - 1:

```
<addr:16>:<size:8>:<rkey:8>:<lid:4>:<qpn:6>:<gid present:1>:<gid:32>
```

1. The client creates an RC QP and sends `POST /rdma/connect` with its descriptor in
   `x-amz-rdma-token`. The reply is `x-amz-rdma-reply: 200:<server token>`. Both sides start at PSN 0,
   and the QP stays up across transfers.
2. A `GET` with a token gets its bytes written to the address in the token before the reply goes out.
   The reply has `x-amz-rdma-reply: 200` or `206`, `x-amz-rdma-bytes-transferred` and `Content-Length: 0`.
3. Refusals: `501` with `x-amz-rdma-reply: 501` for a token whose GID and QPN match no connected QP,
   which includes every DC token, an S3 error without that header for a malformed or too small token, and `503 RDMATransferError` if a transfer started
   and failed. The server never silently falls back to HTTP.

Transfers on one QP are posted in submission order and never interleave, and writes within a transfer
go to ascending addresses. Up to 64 MiB is one RDMA WRITE, above that it is split into 16 MiB WRITEs.

## Not there yet

- Requests are not authenticated, so run it on a trusted network only.
- cuObject and AIStor SDK clients: they use DC, which gets a `501`. The token layout comes from
  versitygw and the MinIO SDKs and has not been checked against a real client.
- The reply format and PSN of `POST /rdma/connect` are this server's own. AIStor does not document them.
- Path-style URLs only, no `CopyObject`, `ListParts` or `ListMultipartUploads`.
- A PUT over HTTP is buffered in the heap before it is copied into the arena.
