# Self-Hosted CI/CD Controller

## 1. Overview

This repository contains a lightweight, self-hosted CI/CD system designed to automate the deployment of containerized applications on a single server running Kubernetes. It operates by listening for Git webhooks and executing a deployment script that handles the entire build, push, and deploy lifecycle.

The system is architected for reliability, incorporating zero-downtime rolling updates and automatic rollbacks in the event of a failed deployment. It is ideal for small to medium-sized projects where a full-featured, third-party CI/CD service is unnecessary or cost-prohibitive.

---

## 2. Core Features

-   **Webhook Driven:** Initiates deployments automatically upon a `git push` to a specified branch.
-   **Zero-Downtime Deployments:** Leverages Kubernetes' native rolling update strategy to ensure the application remains available during updates.
-   **Automated Rollbacks:** Monitors the health of a new deployment. If the new version fails to become healthy, the system automatically reverts to the last known stable version.
-   **Intelligent Image Tagging:**
    -   Uses unique Git commit hashes for immutable, traceable image versions.
    -   Maintains floating `latest` and `last-stable` tags for easy management and rollback.
-   **Local Registry Integration:** Natively builds for and pushes to a local Docker registry running on the same host, keeping all artifacts on-premises.
-   **Resource-Aware Building:** Uses techniques to limit the resource consumption of the Docker build process to prevent service disruption on a live server.
-   **Automatic Cleanup:** Prunes stale Docker images after a successful deployment to conserve disk space.

---

## 3. Prerequisites

For this system to function, the following components must be installed and configured on the host server.

### 3.1. Server Requirements

-   **A Linux-based OS** (e.g., Ubuntu 22.04, Debian 11).
-   **Docker Engine** and **Docker Compose**.
-   **A Kubernetes distribution** (e.g., K3s, MicroK8s).
-   **`kubectl`** configured to communicate with the local cluster.
-   **Git** command-line tool.
-   **An SSH key** configured for read access to your Git repositories (if they are private).
-   **Node.js** (v18.x or later) and **`pm2`** (`npm install -g pm2`).

### 3.2. Application Repository Requirements

The application repository that you intend to deploy must contain:

1.  **A `Dockerfile`:** This file must define how to build a container image of the application.
2.  **Kubernetes Manifests:** A set of Kubernetes configuration files (preferably managed with Kustomize) that defines, at a minimum:
    -   A `Deployment` resource.
    -   A `Service` resource.
    -   An `Ingress` resource (if applicable).
    -   The `Deployment` must be configured to pull its image from the local registry (e.g., `image: localhost:5000/my-app`).

---

## 4. Architecture & Workflow

The system consists of two main components running on the host server: a **Webhook Receiver** and a **Deployment Script**.

1.  **Git Push:** A developer pushes a commit to the application's repository.
2.  **Webhook Event:** The Git provider (GitHub, GitLab, etc.) sends a webhook to the **Webhook Receiver**.
3.  **Trigger Script:** The receiver validates the webhook's secret and executes the **Deployment Script**, passing the new commit hash as an argument.
4.  **Execute Deployment:** The script performs the following steps on the host machine:
    - a.  **Pull:** Navigates to the application repository and pulls the latest code.
    - b.  **Backup:** Re-tags the current `latest` Docker image as `last-stable`.
    - c.  **Build:** Builds a new Docker image, tagging it with the unique commit hash.
    - d.  **Push:** Pushes the new image (tagged as both `latest` and with its commit - hash) and the `last-stable` image to the local Docker registry.
    - e.  **Deploy:** Uses `kubectl` to update the Kubernetes Deployment to use the new commit-hashed image tag, which triggers a rolling update.
    - f.  **Verify:** Monitors the rollout status.
    - g.  **Finalize:** If the rollout is successful, it cleans up old images. If it fails, it automatically triggers a `kubectl rollout undo` to revert to the previous stable version.

---

## 5. Setup & Configuration

### Step 5.1: Set Up the Local Docker Registry (One-Time Setup)

This registry is essential for storing the built images where Kubernetes can access them.

1.  **Create Directory and Docker Compose File:**
    ```bash
    sudo mkdir -p /opt/registry/data
    sudo nano /opt/registry/docker-compose.yml
    ```
    Paste the following into the file:
    ```yml
    version: '3'
    services:
      registry:
        image: registry:2
        container_name: local-docker-registry
        restart: always
        ports:
          - "5000:5000"
        volumes:
          - ./data:/var/lib/registry
    ```

2.  **Configure Docker and Kubernetes to Trust the Registry:**
    Because the registry is insecure (HTTP), you must configure both the Docker daemon and the Kubernetes container runtime.

    **For Docker:**
    ```bash
    sudo nano /etc/docker/daemon.json
    ```
    Add the following content (merge if the file exists):
    ```json
    {
      "insecure-registries": ["localhost:5000"]
    }
    ```

    **For K3s:** (Path may vary for other Kubernetes distributions)
    ```bash
    sudo nano /etc/rancher/k3s/registries.toml
    ```
    Add the following content:
    ```toml
    [registries."localhost:5000"]
      endpoint = ["http://localhost:5000"]
    ```

3.  **Restart Services to Apply Configuration:**
    ```bash
    sudo systemctl restart docker
    sudo systemctl restart k3s # or microk8s
    ```

4.  **Start the Registry:**
    ```bash
    cd /opt/registry
    sudo docker compose up -d
    ```

### Step 5.2: Install the Controller

Clone this repository onto your server, for example, in `/opt`.

```bash
sudo git clone https://github.com/a-essam23/ci-cd-pipeline.git /opt/ci-cd-controller
```

### Step 5.3: Configure the Controller

Create and edit a `.env` file to configure the controller for your specific application.

```bash
cd /opt/ci-cd-controller/config
sudo cp .env.example .env
sudo nano .env
```

**Configuration Variables:**

-   `WEBHOOK_SECRET`: A strong, random string used to secure the webhook endpoint. **Must match the secret in your Git provider settings.**
-   `APP_REPO_PATH`: The absolute path to the application repository on the server (e.g., `/opt/my-app`).
-   `APP_NAME`: The name of the Kubernetes `Deployment` resource to be updated (e.g., `my-app-deployment`).
-   `REGISTRY_URL`: The URL of the local Docker registry (e.g., `localhost:5000`).
-   `K8S_NAMESPACE`: The Kubernetes namespace where the application is deployed.
-   `SSH_KEY_NAME`: (Optional) The filename of the private SSH key (e.g., `id_rsa` or `deploy_key`) located in `/root/.ssh/`. If this is not set, the script will attempt to pull via HTTPS.

### Step 5.4: Run the Webhook Receiver

The receiver runs as a Node.js process managed by `pm2` to ensure it's always online.

```bash
# Navigate to the receiver directory
cd /opt/ci-cd-controller/webhook-receiver

# Install dependencies
npm install

# Start the service with pm2
pm2 start index.js --name "webhook-receiver"

# Save the process list and configure pm2 to start on boot
pm2 save
pm2 startup
# (Run the command output by pm2 startup)
```

---

## 6. Usage: Activating the Pipeline

Once the controller is running, you must configure your application's Git repository to send webhooks to it.

1.  Navigate to your repository's settings on GitHub, GitLab, or your provider of choice.
2.  Go to the "Webhooks" section and add a new webhook.
3.  Configure the webhook with the following settings:
    -   **Payload URL:** `http://<YOUR_SERVER_IP>:9000/webhook/git-update`
    -   **Content type:** `application/json`
    -   **Secret:** The exact value you set for `WEBHOOK_SECRET` in the `.env` file.
    -   **Events:** Select to trigger on "push" events only.
4.  Save the webhook.

The system is now live. Any push to the `main` branch will automatically trigger a new deployment.