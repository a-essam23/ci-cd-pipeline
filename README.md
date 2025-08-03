### Project Structure: `ci-cd-controller`
```txt
ci-cd-controller/
├── README.md
├── config/
│   └── .env.example
├── scripts/
│   └── deploy.sh
└── webhook-receiver/
    ├── package.json
    └── index.js
```

# Self-Hosted CI/CD Controller

## 🚀 Overview

This repository contains a lightweight, cost-effective, and self-hosted CI/CD pipeline designed to run on a single VPS. It listens for Git push events via a webhook and automates the process of building, deploying, and managing a Dockerized application on a local Kubernetes (K3s/MicroK8s) cluster.

The entire system is designed for resilience, featuring zero-downtime rolling updates and automatic rollbacks in case of deployment failure.

### ✨ Core Features

*   **Webhook Driven:** Uses a secure webhook from GitHub/GitLab to trigger deployments instantly on a `git push`.
*   **Automated Docker Builds:** Automatically builds a new Docker image from the application source code.
*   **Intelligent Image Tagging:**
    *   Uses unique Git commit hashes for immutable image versions (e.g., `:a1b2c3d`).
    *   Maintains floating `latest` and `last-stable` tags for easy reference and rollbacks.
*   **Zero-Downtime Rolling Deploys:** Leverages Kubernetes' native rolling update strategy to ensure the application remains available during an update.
*   **Automatic Rollback on Failure:** Monitors the deployment status. If a new version fails its health checks, the system automatically reverts to the `last-stable` version.
*   **Resource Management:** Limits CPU and memory usage during the Docker build process to prevent overwhelming the host server.
*   **Automatic Image Cleanup:** Prunes old, unused Docker images after a successful deployment to conserve disk space.

### ⚙️ The Workflow

This diagram illustrates the end-to-end process from a code push to a live deployment:

```
Developer         Git Provider        Your VPS
-----------       ------------        -------------------------------------------
     |                  |                               |
1. git push main -----> |                               |
     |                  |                               |
     |           2. Sends Webhook ------------------> Webhook Receiver (Node.js)
     |                  |                               |
     |                  |                      3. Executes deploy.sh script
     |                  |                               |
     |                  |                  4. Fetches latest code from Git Provider
     |                  |                               |
     |                  |                  5. Builds & Pushes Image to Local Registry
     |                  |                               |
     |                  |                  6. Updates Kubernetes Deployment
     |                  |                               |
     |                  |                  7. Monitors Rollout Status
     |                  |                               |
     |                  |                  8. Success or Auto-Rollback
     |                  |                               |
```

### 📋 Setup Instructions

1.  **Clone Repositories:** On your VPS, clone this `ci-cd-controller` repository and your application repository (`roman-classic`) side-by-side.

    ```bash
    git clone <this-repo-url>
    git clone <your-app-repo-url>
    ```

2.  **Configure Environment:** Copy the example environment file and fill in the required values.

    ```bash
    cd ci-cd-controller/config
    cp .env.example .env
    nano .env
    ```

3.  **Install Dependencies:** Install the Node.js dependencies for the webhook receiver.

    ```bash
    cd ../webhook-receiver
    npm install
    ```

4.  **Run the Receiver:** Use a process manager like `pm2` to run the webhook receiver service continuously.

    ```bash
    pm2 start index.js --name "webhook-receiver"
    pm2 save
    pm2 startup
    ```

5.  **Configure Git Provider Webhook:**
    *   Go to your `roman-classic` repository settings on GitHub/GitLab.
    *   Navigate to "Webhooks" and add a new webhook.
    *   **Payload URL:** `http://<your-vps-ip>:9000/webhook/git-update`
    *   **Content type:** `application/json`
    *   **Secret:** Use the same secret you defined in your `.env` file.
    *   **Events:** Select "Just the push event".