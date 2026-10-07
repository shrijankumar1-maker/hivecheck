#!/usr/bin/env python3

import os
import sys

import scoring


MIN_ROC_AUC = 0.86
MIN_RECALL = 0.50
MAX_AUC_DROP = 0.01


def format_pct(value):
    return f"{value * 100:.1f}%"


def write_summary(report):
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")

    if not summary_path:
        return

    try:
        with open(summary_path, "a", encoding="utf-8") as f:
            f.write(report)
            f.write("\n")
    except OSError:
        # The gate itself should still produce its normal result if
        # GitHub's summary file cannot be written.
        pass


def main():
    if len(sys.argv) != 3:
        print(
            "Usage: python gate.py BASELINE_DIR CANDIDATE_DIR",
            file=sys.stderr,
        )
        return 1

    baseline_dir = sys.argv[1]
    candidate_dir = sys.argv[2]

    try:
        baseline = scoring.load_model(baseline_dir)
        candidate = scoring.load_model(candidate_dir)

        rows, labels = scoring.read_holdout("data/holdout.csv")

        baseline_probs = scoring.predict_proba(baseline, rows)
        candidate_probs = scoring.predict_proba(candidate, rows)

        baseline_auc = scoring.roc_auc(labels, baseline_probs)
        candidate_auc = scoring.roc_auc(labels, candidate_probs)

        baseline_recall = scoring.recall_at(
            labels,
            baseline_probs,
            baseline["threshold"],
        )

        candidate_recall = scoring.recall_at(
            labels,
            candidate_probs,
            candidate["threshold"],
        )

        baseline_flagged = scoring.flagged_share(
            baseline_probs,
            baseline["threshold"],
        )

        candidate_flagged = scoring.flagged_share(
            candidate_probs,
            candidate["threshold"],
        )

    except Exception as exc:
        print(f"FAIL unable to evaluate models: {exc}")
        return 1

    auc_floor = max(MIN_ROC_AUC, baseline_auc - MAX_AUC_DROP)

    failures = []

    if candidate_auc < MIN_ROC_AUC:
        failures.append(
            f"ROC AUC {candidate_auc:.4f} is below the floor "
            f"{MIN_ROC_AUC:.2f}"
        )

    if candidate_recall < MIN_RECALL:
        failures.append(
            f"recall {candidate_recall:.4f} is below the floor "
            f"{MIN_RECALL:.2f}"
        )

    if candidate_auc < baseline_auc - MAX_AUC_DROP:
        failures.append(
            f"ROC AUC {candidate_auc:.4f} is more than "
            f"{MAX_AUC_DROP:.2f} below baseline {baseline_auc:.4f}"
        )

    lines = [
        "| Metric | Baseline | Candidate |",
        "|---|---:|---:|",
        f"| ROC AUC | {baseline_auc:.4f} | {candidate_auc:.4f} |",
        (
            f"| threshold | {baseline['threshold']} | "
            f"{candidate['threshold']} |"
        ),
        (
            f"| recall at threshold | {baseline_recall:.4f} | "
            f"{candidate_recall:.4f} |"
        ),
        (
            f"| hives flagged | {format_pct(baseline_flagged)} | "
            f"{format_pct(candidate_flagged)} |"
        ),
        "",
        f"Candidate ROC AUC floor: {auc_floor:.4f}",
        f"Absolute ROC AUC floor: {MIN_ROC_AUC:.2f}",
        f"Recall floor: {MIN_RECALL:.2f}",
        f"Maximum allowed ROC AUC drop: {MAX_AUC_DROP:.2f}",
    ]

    if failures:
        lines.extend(
            [
                "",
                "FAIL the candidate does not satisfy the model-quality gate:",
            ]
        )
        lines.extend(f"- {failure}" for failure in failures)

        report = "\n".join(lines)
        print(report)
        write_summary(report)

        return 1

    lines.extend(
        [
            "",
            "PASS the candidate clears both floors and is no worse "
            "than the baseline",
        ]
    )

    report = "\n".join(lines)
    print(report)
    write_summary(report)

    return 0


if __name__ == "__main__":
    sys.exit(main())
