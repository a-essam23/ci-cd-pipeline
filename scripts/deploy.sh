#!/bin/bash

# ==============================================================================
# Self-Hosted CI/CD Deployment Script (Host Runner Version)
#
# Executes directly on the host machine. Expects git, docker, and kubectl
# to be in the system's PATH. Environment variables are inherited from the
# calling process (pm2 > node > this script).
# ==============================================================================

# Exit immediately if any command fails
set -e

# --- Helper Functions ---
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] - INFO - $1"
}

log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] - ERROR - $1" >&2
}

# --- SSH Agent Setup (Optional) ---
# If an SSH key is specified, load it for private git repo access.
if [ -n "$SSH_KEY_NAME" ]; then
    log "SSH_KEY_NAME is set. Initializing SSH Agent and adding key: ${SSH_KEY_NAME}"
    eval "$(ssh-agent -s)" > /dev/null
    
    # Assumes the user running the pm2 process has the key.
    # If pm2 is run by root, it will look in /root/.ssh/
    SSH_KEY_PATH="/root/.ssh/${SSH_KEY_NAME}"
    if [ -f "$SSH_KEY_PATH" ]; then
        ssh-add "$SSH_KEY_PATH" > /dev/null
        log "Successfully added SSH key."
    else
        log_error "SSH key specified (${SSH_KEY_NAME}) but not found at ${SSH_KEY_PATH}. Aborting."
        exit 1
    fi
else
    log "No SSH_KEY_NAME specified. Proceeding with default (HTTPS) git authentication."
fi

# --- Script Variables ---
NEW_COMMIT_HASH=$1
if [ -z "$NEW_COMMIT_HASH" ]; then
    log_error "No commit hash provided."
    exit 1
fi

COMMIT_IMAGE="${REGISTRY_URL}/${APP_NAME}:${NEW_COMMIT_HASH}"
LATEST_IMAGE="${REGISTRY_URL}/${APP_NAME}:latest"
STABLE_IMAGE="${REGISTRY_URL}/${APP_NAME}:last-stable"

# --- Deployment Steps ---

log "Starting deployment for commit ${NEW_COMMIT_HASH}..."

# 1. Fetch Latest Code
log "Navigating to app repository: ${APP_REPO_PATH}"
cd "$APP_REPO_PATH" || { log_error "Application repository not found!"; exit 1; }

log "Marking repository as safe for git operations..."
git config --global --add safe.directory "$APP_REPO_PATH"

log "Pulling latest changes from main branch..."
git pull origin main

# 2. Backup Current Running Image
log "Backing up current ':latest' image to ':last-stable'..."
if docker image inspect "$LATEST_IMAGE" > /dev/null 2>&1; then
    docker tag "$LATEST_IMAGE" "$STABLE_IMAGE"
    log "Successfully tagged current image as ':last-stable'."
else
    log "No existing ':latest' image found to back up. Skipping."
fi

# 3. Build New Docker Image
log "Building new Docker image: ${COMMIT_IMAGE}"
# NOTE: Removed --memory and --cpus flags as they are invalid for 'docker build'.
# The NODE_OPTIONS build-arg is still useful to limit memory for the build process itself.
if docker run --rm \
  --cpus="0.75" \
  --memory="1536m" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)":/app \
  -w /app \
  docker:25.0 \
  sh -c 'DOCKER_BUILDKIT=1 docker build --build-arg NODE_OPTIONS="--max-old-space-size=1024" -t '"$COMMIT_IMAGE"' .' ; then
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
if docker image inspect "$STABLE_IMAGE" > /dev/null 2>&1; then
    docker push "$STABLE_IMAGE"
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