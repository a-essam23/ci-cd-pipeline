#!/bin/bash

# ==============================================================================
# Self-Hosted CI/CD Deployment Script
#
# This script automates the deployment of a Dockerized application to a
# local Kubernetes cluster, featuring zero-downtime rolling updates and
# automatic rollbacks on failure.
#
# Usage: ./deploy.sh <COMMIT_HASH>
# ==============================================================================

# For running inside a container or a controlled environment, ensure the PATH includes necessary binaries.
export PATH=$PATH:/usr/local/bin:/usr/bin
set -e

# --- Configuration ---
# Load environment variables from the config file
CONFIG_PATH="$(dirname "$0")/../config/.env"
if [ -f "$CONFIG_PATH" ]; then
    export $(grep -v '^#' "$CONFIG_PATH" | xargs)
else
    echo "🚨 ERROR: Configuration file not found at $CONFIG_PATH"
    exit 1
fi

# --- Script Variables ---
NEW_COMMIT_HASH=$1
if [ -z "$NEW_COMMIT_HASH" ]; then
    echo "🚨 ERROR: No commit hash provided. Usage: ./deploy.sh <COMMIT_HASH>"
    exit 1
fi

# Docker image names
COMMIT_IMAGE="${REGISTRY_URL}/${APP_NAME}:${NEW_COMMIT_HASH}"
LATEST_IMAGE="${REGISTRY_URL}/${APP_NAME}:latest"
STABLE_IMAGE="${REGISTRY_URL}/${APP_NAME}:last-stable"

# --- Helper Functions ---
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] - INFO - $1"
}

log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] - ERROR - $1" >&2
}

# --- Deployment Steps ---

log "Starting deployment for commit ${NEW_COMMIT_HASH}..."

# 1. Fetch Latest Code
log "Navigating to app repository: ${APP_REPO_PATH}"
cd "$APP_REPO_PATH" || { log_error "Application repository not found!"; exit 1; }

log "Pulling latest changes from main branch..."
git pull origin main

# 2. Backup Current Running Image
log "Backing up current ':latest' image to ':last-stable'..."
CURRENT_LATEST_ID=$(docker images -q "$LATEST_IMAGE")
if [ -n "$CURRENT_LATEST_ID" ]; then
    docker tag "$LATEST_IMAGE" "$STABLE_IMAGE"
    log "Successfully tagged current image ${CURRENT_LATEST_ID} as ':last-stable'."
else
    log "No existing ':latest' image found to back up. Skipping."
fi

# 3. Build New Docker Image with Resource Limits
log "Building new Docker image: ${COMMIT_IMAGE}"
# Limit build resources to avoid overwhelming the VPS. Adjust as needed.
# --memory="1536m" is 1.5GB. --cpus="1.5" allows up to 1.5 CPU cores.
# NODE_OPTIONS limits memory for the Node.js build process itself.
if docker build \
    --build-arg NODE_OPTIONS="--max-old-space-size=1024" \
    --memory="1536m" \
    --cpus="1.5" \
    -t "$COMMIT_IMAGE" . ; then
    log "✅ Docker image built successfully."
else
    log_error "🚨 Docker build failed. Aborting deployment."
    exit 1
fi

# 4. Promote and Push to Local Registry
log "Tagging new build as ':latest'..."
docker tag "$COMMIT_IMAGE" "$LATEST_IMAGE"

log "Pushing images to local registry at ${REGISTRY_URL}..."
docker push "$LATEST_IMAGE"
if [ -n "$CURRENT_LATEST_ID" ]; then
    docker push "$STABLE_IMAGE"
fi

log "Verifying that the new image exists in the local registry..."
# The 'docker image inspect' command will exit with a non-zero status code if the image doesn't exist.
# The >/dev/null 2>&1 part silences the output, we only care about the success/failure.
if docker image inspect "$COMMIT_IMAGE" >/dev/null 2>&1; then
    log "✅ Image ${COMMIT_IMAGE} verified."
else
    log_error "🚨 CRITICAL FAILURE: Newly built image was not found in the local registry. Aborting deployment."
    # At this point, we could also trigger a rollback or alert.
    exit 1
fi

# 5. Trigger Kubernetes Rolling Update
log "Updating Kubernetes deployment '${APP_NAME}' to use new image..."
kubectl set image deployment/"${APP_NAME}" "${APP_NAME}"="${COMMIT_IMAGE}" -n "${K8S_NAMESPACE}"

# 6. Verify Deployment and Handle Rollback
log "Watching rollout status... (Timeout: 5 minutes)"
if kubectl rollout status deployment/"${APP_NAME}" -n "${K8S_NAMESPACE}" --watch=true --timeout=5m; then
    log "✅✅✅ Deployment successful! The application is now running version ${NEW_COMMIT_HASH}."

    # 7. Cleanup Old Images
    log "Cleaning up old, untagged images..."
    docker image prune -f
else
    log_error "🚨🚨🚨 Deployment failed! The new version could not become healthy."
    log_error "Initiating automatic rollback to the last stable version..."
    kubectl rollout undo deployment/"${APP_NAME}" -n "${K8S_NAMESPACE}"

    log_error "Restoring ':latest' tag in registry to the last stable version..."
    docker tag "$STABLE_IMAGE" "$LATEST_IMAGE"
    docker push "$LATEST_IMAGE"

    log_error "Rollback complete. The application is running the previous version."
    exit 1
fi

exit 0