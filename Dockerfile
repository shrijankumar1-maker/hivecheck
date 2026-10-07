# The hive check service, with its model inside.
#
#     docker build --build-arg GIT_SHA=$(git rev-parse HEAD) -t hivecheck .

FROM python:3.12-slim

WORKDIR /app

# Dependencies before code, so an edit to app/ does not reinstall them.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ app/
COPY model/ model/

# The commit this image was built from. /health reports it.
ARG GIT_SHA=unknown
ENV GIT_SHA=$GIT_SHA

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
