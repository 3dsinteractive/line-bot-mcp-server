#!/usr/bin/env bash

set +x
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly COMMAND="${1:-local}"

case "${COMMAND}" in
  local|build|start|stop)
    if (( $# > 2 )); then
      echo "Usage: $0 [local|build|start|stop] [image:tag]" >&2
      exit 2
    fi
    readonly LOCAL_IMAGE="${2:-line-bot-mcp-server:local}"
    readonly CONTAINER_NAME="${CONTAINER_NAME:-line-bot-mcp-server}"
    readonly HOST_PORT="${PORT:-8000}"
    if [[ "${COMMAND}" == stop ]]; then
      docker stop "${CONTAINER_NAME}"
      exit 0
    fi
    if [[ "${COMMAND}" != build && -z "${CHANNEL_ACCESS_TOKEN:-}" ]]; then
      echo "CHANNEL_ACCESS_TOKEN is required to start the MCP server." >&2
      exit 1
    fi
    if [[ "${COMMAND}" != start ]]; then
      docker build --pull --tag "${LOCAL_IMAGE}" "${SCRIPT_DIR}" >&2
      echo "Built ${LOCAL_IMAGE}" >&2
    fi
    if [[ "${COMMAND}" != build ]]; then
      if [[ "${MCP_TRANSPORT:-http}" == stdio ]]; then
        exec docker run --rm -i \
          --env CHANNEL_ACCESS_TOKEN \
          --env DESTINATION_USER_ID \
          --env LINE_MESSAGING_API_BASE_URL \
          --env MCP_TRANSPORT=stdio \
          "${LOCAL_IMAGE}"
      fi
      if [[ "${MCP_TRANSPORT:-http}" != http ]]; then
        echo "MCP_TRANSPORT must be 'http' or 'stdio'." >&2
        exit 1
      fi
      if [[ ! "${HOST_PORT}" =~ ^[1-9][0-9]*$ ]] || (( HOST_PORT > 65535 )); then
        echo "PORT must be an integer between 1 and 65535." >&2
        exit 1
      fi
      docker run --detach --rm \
        --name "${CONTAINER_NAME}" \
        --publish "127.0.0.1:${HOST_PORT}:8000" \
        --env CHANNEL_ACCESS_TOKEN \
        --env DESTINATION_USER_ID \
        --env LINE_MESSAGING_API_BASE_URL \
        --env MCP_TRANSPORT=http \
        "${LOCAL_IMAGE}"
      echo "MCP endpoint: http://127.0.0.1:${HOST_PORT}/mcp"
    fi
    exit 0
    ;;
  push)
    shift
    ;;
  *)
    if (( $# != 3 )); then
      echo "Usage: $0 [local|build|start|stop] [image:tag]" >&2
      echo "       $0 push <repository> <tag> <Docker Hub username> < token" >&2
      exit 2
    fi
    ;;
esac

readonly IMAGE_REPOSITORY="${1:?Image repository is required}"
readonly IMAGE_TAG="${2:?Image tag is required}"
readonly DOCKER_HUB_USERNAME="${3:?Docker Hub username is required}"
readonly IMAGE="${IMAGE_REPOSITORY}:${IMAGE_TAG}"
readonly PLATFORMS="${PLATFORMS:-linux/amd64}"

DOCKER_HUB_TOKEN=""
IFS= read -r DOCKER_HUB_TOKEN || true
[[ -n "${DOCKER_HUB_TOKEN}" ]] || {
  echo "Docker Hub token is required on stdin." >&2
  exit 1
}

case "${DOCKER_HUB_USERNAME}" in
  *[!a-zA-Z0-9_-]*) echo "Docker Hub username contains unsupported characters." >&2; exit 1 ;;
esac
case "${IMAGE_REPOSITORY}" in
  "${DOCKER_HUB_USERNAME}/"*) ;;
  *) echo "Image repository must be in the Docker Hub username namespace." >&2; exit 1 ;;
esac
case "${DOCKER_HUB_TOKEN}" in
  *[!a-zA-Z0-9_.-]*) echo "Docker Hub token contains unsupported characters." >&2; exit 1 ;;
esac
export DOCKER_HUB_USERNAME DOCKER_HUB_TOKEN

umask 077
DOCKER_CONFIG="$(mktemp -d)"
export DOCKER_CONFIG
trap 'rm -rf -- "${DOCKER_CONFIG}"' EXIT

cat > "${DOCKER_CONFIG}/docker-credential-centermcp" <<'HELPER'
#!/usr/bin/env bash
set +x
set -euo pipefail
case "${1:-}" in
  store) cat > /dev/null ;;
  get)
    SERVER_URL=""
    IFS= read -r SERVER_URL || true
    case "${SERVER_URL}" in
      https://index.docker.io/*|https://registry-1.docker.io|https://registry-1.docker.io/*|registry-1.docker.io|docker.io|https://docker.io|https://docker.io/*) ;;
      *) exit 1 ;;
    esac
    printf '{"Username":"%s","Secret":"%s"}\n' \
      "${DOCKER_HUB_USERNAME}" "${DOCKER_HUB_TOKEN}"
    ;;
  erase) ;;
  *) exit 1 ;;
esac
HELPER

chmod 700 "${DOCKER_CONFIG}/docker-credential-centermcp"
export PATH="${DOCKER_CONFIG}:${PATH}"
printf '%s\n' '{"credsStore":"centermcp"}' > "${DOCKER_CONFIG}/config.json"

printf '%s' "${DOCKER_HUB_TOKEN}" |
  docker login --username "${DOCKER_HUB_USERNAME}" --password-stdin

docker buildx build \
  --platform "${PLATFORMS}" \
  --pull \
  --tag "${IMAGE}" \
  --push \
  "${SCRIPT_DIR}"

echo "Published ${IMAGE}"
