"""Scoring helpers for hivecheck models. Standard library only.

    import scoring
    model = scoring.load_model("model")                  # a folder holding model.json
    rows, labels = scoring.read_holdout("data/holdout.csv")
    probs = scoring.predict_proba(model, rows)
    scoring.roc_auc(labels, probs)                       # 0.8665
    scoring.recall_at(labels, probs, model["threshold"]) # 0.5427

A model is the dict stored in model.json: its feature names, one weight per
feature, an intercept, the threshold at which a hive is flagged, and a version.
"""
import csv
import json
import math
from pathlib import Path


def load_model(model_dir):
    """The model in <model_dir>/model.json, as a dict."""
    return json.loads((Path(model_dir) / "model.json").read_text())


def read_holdout(path="data/holdout.csv"):
    """The labelled readings in a CSV file. Returns (rows, labels): rows is a list
    of dicts mapping each feature name to a float, labels a list of 0 and 1
    (1 means the colony collapsed)."""
    rows, labels = [], []
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            labels.append(int(r.pop("collapsed")))
            rows.append({k: float(v) for k, v in r.items()})
    return rows, labels


def predict_proba(model, rows):
    """The probability of collapse for each row, in order."""
    out = []
    for r in rows:
        z = model["intercept"] + sum(w * r[name] for name, w in zip(model["features"], model["weights"]))
        out.append(1.0 / (1.0 + math.exp(-z)))
    return out


def roc_auc(labels, probs):
    """The ROC AUC: the chance that a collapsing hive scores above a healthy one.
    Ties count half."""
    pairs = sorted(zip(probs, labels))
    ranks, i = [0.0] * len(pairs), 0
    while i < len(pairs):
        j = i
        while j + 1 < len(pairs) and pairs[j + 1][0] == pairs[i][0]:
            j += 1
        for k in range(i, j + 1):
            ranks[k] = (i + j) / 2 + 1
        i = j + 1
    pos = sum(1 for _, y in pairs if y == 1)
    neg = len(pairs) - pos
    if pos == 0 or neg == 0:
        raise ValueError("roc_auc needs at least one positive and one negative label")
    rank_sum = sum(r for r, (_, y) in zip(ranks, pairs) if y == 1)
    return (rank_sum - pos * (pos + 1) / 2) / (pos * neg)


def recall_at(labels, probs, threshold):
    """The share of collapsing hives that are flagged, a probability at or above threshold."""
    hits = [p >= threshold for p, y in zip(probs, labels) if y == 1]
    if not hits:
        raise ValueError("recall_at needs at least one positive label")
    return sum(hits) / len(hits)


def flagged_share(probs, threshold):
    """The share of all hives that are flagged."""
    return sum(p >= threshold for p in probs) / len(probs)
