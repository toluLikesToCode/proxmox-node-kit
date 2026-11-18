#!/bin/bash
# Runs advisor/sync.sh against the real Open WebUI image pinned in app/compose.yaml (not a stub).
# Needs Docker and a few minutes; CI runs it as its own job. Usage: bash tests/integration.sh
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE=$(sed -n 's/^ *image: *//p' app/compose.yaml)
MODEL=$(jq -r .base_model_id app/advisor/model.json)
NET=owui-it-$$
cleanup() { docker rm -f "$NET-owui" "$NET-upstream" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker build -q -t node-kit-tests tests >/dev/null
docker network create "$NET" >/dev/null
docker run -d --name "$NET-upstream" --network "$NET" --network-alias upstream -v "$PWD:/repo:ro" node-kit-tests \
  python3 /repo/tests/stubs/openrouter_stub.py 8000 "$MODEL" >/dev/null
# The seed values are the opposite of what the advisor needs, so only sync.sh can set them right.
docker run -d --name "$NET-owui" --network "$NET" --network-alias owui --tmpfs /app/backend/data \
  -e OPENAI_API_BASE_URL=http://upstream:8000 -e OPENAI_API_KEY=unused -e ENABLE_OLLAMA_API=false \
  -e ENABLE_API_KEYS=true -e WEBUI_SECRET_KEY=integration-test -e ENABLE_TITLE_GENERATION=false \
  -e ENABLE_TAGS_GENERATION=true -e ENABLE_FOLLOW_UP_GENERATION=true -e ENABLE_AUTOCOMPLETE_GENERATION=true \
  -e ENABLE_SEARCH_QUERY_GENERATION=true -e ENABLE_RETRIEVAL_QUERY_GENERATION=true \
  "$IMAGE" >/dev/null
docker run --rm --network "$NET" -e "IMAGE=$IMAGE" -v "$PWD:/repo" node-kit-tests bash tests/integration-run.sh
