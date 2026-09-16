# Item Price Check

A small internal tool for looking up an item by name, SKU, or barcode and
seeing its current price.

## Stack

- Backend: Python + Flask (`server.py`)
- Storage: SQLite (`db/items.db`, created automatically on first run)
- Frontend: static HTML/CSS/JS (`public/`), no build step

This is a deliberately small MVP: one search endpoint, one page, no
authentication, no admin UI. See the schema in `db/schema.sql` for the data
model.

## Running locally

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python server.py
```

Then open http://localhost:5000.

On first run, the app creates `db/items.db` and loads the sample catalog
from `db/seed.sql` (about 15 example items). Delete `db/items.db` and
restart the app to reseed from scratch.

## Adding or changing items

There is no admin UI yet. To add or edit items directly:

```bash
sqlite3 db/items.db
sqlite> INSERT INTO items (sku, barcode, name, description, price, currency, updated_at)
   ...> VALUES ('SKU-9001', NULL, 'New Item', NULL, 12.50, 'USD', '2026-09-16T00:00:00Z');
```

Or edit `db/seed.sql` and delete `db/items.db` to start from a fresh seed.

## Running tests

```bash
pip install pytest
pytest
```

## API

```
GET /api/items/search?q=<term>
```

Matches, in order: exact SKU or barcode (case-insensitive), then falls back
to a case-insensitive partial match on item name. Returns a JSON array of
items (capped at 20 results).
