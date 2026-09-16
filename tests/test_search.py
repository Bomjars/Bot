import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import pytest

from server import create_app


@pytest.fixture
def client(tmp_path):
    db_path = tmp_path / "test_items.db"
    app = create_app(db_path=str(db_path))
    app.config["TESTING"] = True
    with app.test_client() as test_client:
        yield test_client


def search(client, q):
    response = client.get("/api/items/search", query_string={"q": q})
    assert response.status_code == 200
    return response.get_json()


def test_exact_sku_match(client):
    items = search(client, "SKU-1001")
    assert len(items) == 1
    assert items[0]["sku"] == "SKU-1001"
    assert items[0]["name"] == "Standard Widget"


def test_exact_sku_match_is_case_insensitive(client):
    items = search(client, "sku-1001")
    assert len(items) == 1
    assert items[0]["sku"] == "SKU-1001"


def test_exact_barcode_match(client):
    items = search(client, "012345678905")
    assert len(items) == 1
    assert items[0]["sku"] == "SKU-1001"


def test_partial_name_match_is_case_insensitive(client):
    items = search(client, "widget")
    names = {item["name"] for item in items}
    assert names == {"Standard Widget", "Deluxe Widget", "Widget Mounting Bracket"}


def test_no_match_returns_empty_list(client):
    assert search(client, "doesnotexist12345") == []


def test_empty_query_returns_empty_list(client):
    assert search(client, "") == []


def test_whitespace_only_query_returns_empty_list(client):
    assert search(client, "   ") == []


def test_like_wildcard_characters_are_escaped(client):
    assert search(client, "%") == []
    assert search(client, "_") == []


def test_result_shape_has_expected_fields(client):
    items = search(client, "SKU-1001")
    item = items[0]
    for field in ("id", "sku", "barcode", "name", "description", "price", "currency", "updated_at"):
        assert field in item
