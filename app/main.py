"""The hive check service.

    uvicorn app.main:app --host 0.0.0.0 --port 8000

It loads the model once at startup and answers two questions. Is this process
able to score a reading right now, and should a beekeeper open this hive this week.
"""
import json
import math
import os
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from pydantic import BaseModel, Field

# The folder holding model.json. An environment variable, so a container can be
# pointed at a different model without rebuilding the image.
MODEL_DIR = Path(os.environ.get("MODEL_DIR", Path(__file__).resolve().parents[1] / "model"))

# The commit the image was built from, baked in by `docker build --build-arg GIT_SHA=...`.
# /health reports it, so one request tells you which version is live.
GIT_SHA = os.environ.get("GIT_SHA", "unknown")


class Reading(BaseModel):
    """One weekly reading from a hive's sensors."""
    brood_temp_c: float = Field(ge=20, le=45)
    weight_change_kg: float = Field(ge=-15, le=15)
    humidity_pct: float = Field(ge=0, le=100)
    buzz_hz: float = Field(ge=50, le=600)
    mite_load: float = Field(ge=0, le=60)


class Verdict(BaseModel):
    collapse_risk: float
    inspect: bool
    threshold: float
    model_version: str


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.model = json.loads((MODEL_DIR / "model.json").read_text())
    yield


app = FastAPI(title="Hive check", version="1.0.0", lifespan=lifespan)


@app.get("/health")
def health():
    return {
        "status": "ok",
        "model_version": app.state.model["model_version"],
        "git_sha": GIT_SHA,
    }


@app.post("/predict", response_model=Verdict)
def predict(reading: Reading):
    model = app.state.model
    z = model["intercept"] + sum(
        w * getattr(reading, name) for name, w in zip(model["features"], model["weights"])
    )
    p = 1.0 / (1.0 + math.exp(-z))
    return Verdict(
        collapse_risk=round(p, 4),
        inspect=p >= model["threshold"],
        threshold=model["threshold"],
        model_version=model["model_version"],
    )
