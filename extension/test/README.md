# Testing this extension
This directory contains all the tests for this extension. The `sql` directory holds tests that are written as [SQLLogicTests](https://duckdb.org/dev/sqllogictest/intro.html):

- `httpfpga.test` reads objects from the object server with `read_parquet('httpfpga://...')`, over a host socket; the FPGA is not involved.
- `httpfpga_decode.test` reads them with `read_oasis()`, so the FPGA fetches and decodes the columns.

Run them on the board host with the board programmed: loading the extension maps 1 GiB huge pages and opens the FPGA, and on any other host it stops with `Your system has 0 free 1GiB huge pages`. `OASIS_SERVER` is the object server's IP address without a port, e.g. `OASIS_SERVER=10.253.74.5` (the tests use port 9000); without it both tests are skipped. From `extension/`, after `make`:
```bash
OASIS_SERVER=<object server IP> ./build/release/test/unittest --test-dir "$PWD" "test/*"
```
`--test-dir` makes `test/*` select this extension's tests; without it the pattern can select DuckDB's own tests instead.
