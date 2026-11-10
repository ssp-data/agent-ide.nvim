def test_late_rows(con):
    assert con.execute("select count(*) from orders").fetchone()[0] == 42
