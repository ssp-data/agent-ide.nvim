import duckdb


def run(con: duckdb.DuckDBPyConnection) -> None:
    con.execute("create table if not exists orders as select * from raw.orders")


def backfill(con, year: int) -> None:
    for month in range(1, 13):
        con.execute("insert into orders select * from raw.orders where year = ? and month = ?", [year, month])
