COPY customer FROM 'data/tpch/customer.parquet' (FORMAT 'parquet');
COPY lineitem FROM 'data/tpch/lineitem.parquet' (FORMAT 'parquet');
COPY nation FROM 'data/tpch/nation.parquet' (FORMAT 'parquet');
COPY orders FROM 'data/tpch/orders.parquet' (FORMAT 'parquet');
COPY part FROM 'data/tpch/part.parquet' (FORMAT 'parquet');
COPY partsupp FROM 'data/tpch/partsupp.parquet' (FORMAT 'parquet');
COPY region FROM 'data/tpch/region.parquet' (FORMAT 'parquet');
COPY supplier FROM 'data/tpch/supplier.parquet' (FORMAT 'parquet');
