import os
import sqlite3
from pathlib import Path

from flask import Flask, jsonify, request, send_from_directory

BASE_DIR = Path(__file__).resolve().parent
DEFAULT_DB_PATH = str(BASE_DIR / "db" / "items.db")
SCHEMA_PATH = BASE_DIR / "db" / "schema.sql"
SEED_PATH = BASE_DIR / "db" / "seed.sql"
PUBLIC_DIR = BASE_DIR / "public"

MAX_QUERY_LENGTH = 100
MAX_RESULTS = 20


def get_db_connection(db_path):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn


def init_db(db_path, seed=True):
    is_new = not os.path.exists(db_path) or os.path.getsize(db_path) == 0
    conn = get_db_connection(db_path)
    try:
        conn.executescript(SCHEMA_PATH.read_text())
        if is_new and seed:
            conn.executescript(SEED_PATH.read_text())
        conn.commit()
    finally:
        conn.close()


def escape_like(value):
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def search_items(conn, query):
    query = query.strip()[:MAX_QUERY_LENGTH]
    if not query:
        return []

    exact_rows = conn.execute(
        "SELECT * FROM items WHERE sku = ? COLLATE NOCASE OR barcode = ? COLLATE NOCASE LIMIT ?",
        (query, query, MAX_RESULTS),
    ).fetchall()
    if exact_rows:
        return [dict(row) for row in exact_rows]

    like_pattern = f"%{escape_like(query)}%"
    partial_rows = conn.execute(
        "SELECT * FROM items WHERE name LIKE ? ESCAPE '\\' LIMIT ?",
        (like_pattern, MAX_RESULTS),
    ).fetchall()
    return [dict(row) for row in partial_rows]


def create_app(db_path=None):
    app = Flask(__name__, static_folder=str(PUBLIC_DIR), static_url_path="")
    app.config["DB_PATH"] = db_path or DEFAULT_DB_PATH
    init_db(app.config["DB_PATH"])

    @app.get("/")
    def index():
        return send_from_directory(PUBLIC_DIR, "index.html")

    @app.get("/api/items/search")
    def search():
        query = request.args.get("q", "")
        conn = get_db_connection(app.config["DB_PATH"])
        try:
            results = search_items(conn, query)
        finally:
            conn.close()
        return jsonify(results)

    return app


app = create_app()

if __name__ == "__main__":
    app.run(debug=True, port=5000)
