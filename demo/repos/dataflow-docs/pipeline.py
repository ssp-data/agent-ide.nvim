import duckdb


def run(con: duckdb.DuckDBPyConnection) -> None:
    con.execute("create table if not exists orders as select * from raw.orders")
