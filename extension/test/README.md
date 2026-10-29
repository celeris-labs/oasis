# Testing this extension
This directory contains all the tests for this extension. The `sql` directory holds tests that are written as [SQLLogicTests](https://duckdb.org/dev/sqllogictest/intro.html):

- `httpfpga.test` reads objects from the object server with `read_parquet('httpfpga://...')`, over a host socket; the FPGA is not involved.
- `httpfpga_decode.test` reads them with `read_oasis()`, so the FPGA fetches and decodes the columns.

Both need a programmed board and free 1 GiB huge pages (the extension opens the FPGA when it loads), and run only when `OASIS_SERVER` holds the object server's address. From `extension/`, after `make`:
```bash
OASIS_SERVER=<object server IP> make test
```
