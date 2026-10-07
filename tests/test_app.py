"""Tests for the hive check service. Run with: python -m pytest -v"""
import pytest
from fastapi.testclient import TestClient

from app.main import app

HEALTHY = {"brood_temp_c": 35.0, "weight_change_kg": 0.8, "humidity_pct": 58,
           "buzz_hz": 245, "mite_load": 1.0}
FAILING = {"brood_temp_c": 33.4, "weight_change_kg": -1.6, "humidity_pct": 68,
           "buzz_hz": 285, "mite_load": 4.5}


@pytest.fixture
def client():
    # The with block runs the app's startup, which loads the model.
    with TestClient(app) as c:
        yield c


def test_health_is_ok(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_predict_returns_a_verdict(client):
    body = client.post("/predict", json=HEALTHY).json()
    assert 0 <= body["collapse_risk"] <= 1
    assert body["threshold"] == 0.3


def test_failing_hive_scores_higher_than_healthy_one(client):
    failing = client.post("/predict", json=FAILING).json()
    healthy = client.post("/predict", json=HEALTHY).json()
    assert failing["collapse_risk"] > healthy["collapse_risk"]
    assert failing["inspect"] is True
    assert healthy["inspect"] is False


def test_impossible_reading_is_rejected(client):
    r = client.post("/predict", json={**HEALTHY, "humidity_pct": 140})
    assert r.status_code == 422
