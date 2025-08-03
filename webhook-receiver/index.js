'strict';
const express = require('express');
const crypto = require('crypto');
const { spawn } = require('child_process');
const bodyParser = require('body-parser');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../config/.env') });

const app = express();
const PORT = 9000;
const WEBHOOK_SECRET = process.env.WEBHOOK_SECRET;

if (!WEBHOOK_SECRET) {
  console.error('ERROR: WEBHOOK_SECRET is not defined in the .env file.');
  process.exit(1);
}

// Middleware to verify the webhook signature
const verifySignature = (req, res, next) => {
  const signature = req.headers['x-hub-signature-256'];
  if (!signature) {
    return res.status(401).send('Signature required.');
  }

  const hmac = crypto.createHmac('sha256', WEBHOOK_SECRET);
  hmac.update(req.body); // req.body is the raw buffer here
  const digest = `sha256=${hmac.digest('hex')}`;

  if (!crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(digest))) {
    return res.status(401).send('Invalid signature.');
  }

  next();
};

app.use(bodyParser.raw({ type: 'application/json' }));

app.post('/webhook/git-update', verifySignature, (req, res) => {
  try {
    // Parse the raw body to JSON after signature verification
    const payload = JSON.parse(req.body.toString());

    // Check if it's a push to the main branch
    if (payload.ref !== 'refs/heads/main') {
      return res.status(200).send('Ignored push to non-main branch.');
    }

    const commitHash = payload.after;
    if (!commitHash) {
      return res.status(400).send('Commit hash not found in payload.');
    }
    const shortCommitHash = commitHash.substring(0, 7);

    console.log(`[${new Date().toISOString()}] Received valid push. Triggering deployment for commit: ${shortCommitHash}`);

    // Immediately respond to the webhook to avoid timeouts
    res.status(202).send('Accepted. Deployment process initiated.');

    // Execute the deployment script
    const deployScript = spawn('bash', [path.resolve(__dirname, '../scripts/deploy.sh'), shortCommitHash]);

    deployScript.stdout.on('data', (data) => {
      console.log(`[DEPLOY.SH STDOUT]: ${data.toString().trim()}`);
    });

    deployScript.stderr.on('data', (data) => {
      console.error(`[DEPLOY.SH STDERR]: ${data.toString().trim()}`);
    });

    deployScript.on('close', (code) => {
      if (code === 0) {
        console.log(`[${new Date().toISOString()}] Deployment script finished successfully.`);
      } else {
        console.error(`[${new Date().toISOString()}] Deployment script failed with exit code ${code}.`);
      }
    });

  } catch (error) {
    console.error('Error processing webhook:', error);
    // Don't send a 500 error here if we've already sent a 202,
    // as it would cause a "headers already sent" crash.
    // The console log is sufficient.
  }
});

app.listen(PORT, () => {
  console.log(`Webhook receiver listening on http://localhost:${PORT}`);
});