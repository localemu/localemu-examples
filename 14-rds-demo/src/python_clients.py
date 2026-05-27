"""Python round-trip against the LocalEmu-managed Postgres + MySQL containers.

Usage: python python_clients.py <pg_host:pg_port> <mysql_host:mysql_port>
"""
from __future__ import annotations

import sys

import psycopg2
import pymysql


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: python_clients.py <pg_host:port> <mysql_host:port>", file=sys.stderr)
        return 2

    pg_host, pg_port = sys.argv[1].split(":")
    my_host, my_port = sys.argv[2].split(":")

    # --- PostgreSQL ---
    print(f"→ Postgres connect {pg_host}:{pg_port}")
    pg = psycopg2.connect(host=pg_host, port=int(pg_port), user="admin",
                          password="Secret123", dbname="myapp")
    try:
        with pg, pg.cursor() as cur:
            cur.execute("CREATE TABLE IF NOT EXISTS users (id serial PRIMARY KEY, name text, email text)")
            cur.execute("INSERT INTO users (name, email) VALUES (%s, %s) RETURNING id",
                        ("Tarek", "tarek@tocconsulting.fr"))
            user_id = cur.fetchone()[0]
            cur.execute("SELECT id, name, email FROM users ORDER BY id")
            rows = cur.fetchall()
            for r in rows:
                print(f"   PG row: id={r[0]} name={r[1]} email={r[2]}")
            assert any(r[0] == user_id for r in rows)
    finally:
        pg.close()

    # --- MySQL ---
    print(f"\n→ MySQL connect {my_host}:{my_port}")
    my = pymysql.connect(host=my_host, port=int(my_port), user="root",
                         password="Secret123", database="shopdb")
    try:
        with my.cursor() as cur:
            cur.execute("CREATE TABLE IF NOT EXISTS products "
                        "(id int AUTO_INCREMENT PRIMARY KEY, name varchar(100), price decimal(10,2))")
            cur.execute("INSERT INTO products (name, price) VALUES (%s, %s)",
                        ("LocalEmu Pro", 0.00))
            my.commit()
            cur.execute("SELECT id, name, price FROM products ORDER BY id")
            rows = cur.fetchall()
            for r in rows:
                print(f"   MySQL row: id={r[0]} name={r[1]} price={r[2]}")
            assert any(r[1] == "LocalEmu Pro" for r in rows)
    finally:
        my.close()

    print("\n→ both round-trips OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
