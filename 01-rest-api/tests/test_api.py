"""Three integration tests, real HTTP, no mocks."""
from __future__ import annotations

import uuid

import requests


def test_crud_lifecycle(api_base):
    unique = f"pytest-{uuid.uuid4().hex[:8]}"

    # 1. Create
    r = requests.post(
        f"{api_base}/notes",
        json={"title": f"title-{unique}", "content": "hello from pytest"},
        timeout=15,
    )
    assert r.status_code == 201, r.text
    note_id = r.json()["note_id"]
    assert isinstance(r.json()["created_at"], int)

    # 2. Read back
    r = requests.get(f"{api_base}/notes/{note_id}", timeout=15)
    assert r.status_code == 200
    assert r.json()["title"] == f"title-{unique}"

    # 3. List must include our note
    lst = requests.get(f"{api_base}/notes", timeout=15).json()
    assert note_id in {i["note_id"] for i in lst["items"]}

    # 4. Update (PATCH)
    r = requests.patch(
        f"{api_base}/notes/{note_id}",
        json={"title": f"updated-{unique}"},
        timeout=15,
    )
    assert r.status_code == 200
    body = r.json()
    assert body["title"] == f"updated-{unique}"
    assert body["content"] == "hello from pytest"  # unchanged field preserved
    assert isinstance(body["updated_at"], int)

    # 5. Delete, then 6. GET must return 404
    assert requests.delete(f"{api_base}/notes/{note_id}", timeout=15).status_code == 204
    assert requests.get(f"{api_base}/notes/{note_id}", timeout=15).status_code == 404


def test_create_requires_title(api_base):
    r = requests.post(f"{api_base}/notes", json={"content": "no title"}, timeout=15)
    assert r.status_code == 400
    assert "title" in r.json()["error"].lower()


def test_get_missing_returns_404(api_base):
    missing_id = uuid.uuid4().hex[:10]
    r = requests.get(f"{api_base}/notes/{missing_id}", timeout=15)
    assert r.status_code == 404
