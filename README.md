# hivecheck
New branch got added

Flags beehives at risk of colony collapse from their weekly sensor readings.

    python3 -m venv .venv
    .venv/bin/pip install -r requirements.txt -r requirements-dev.txt
    .venv/bin/python -m pytest -v
    .venv/bin/uvicorn app.main:app --port 8000

`GET /health` says whether the service can score readings and which commit it
runs. `POST /predict` scores one reading. `infra/bootstrap.sh` creates the AWS
side, and `.github/workflows/pipeline.yml` tests and releases every change.
