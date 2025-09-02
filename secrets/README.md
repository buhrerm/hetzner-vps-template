# Secrets Directory

This directory will contain:

1. **GitHub Deploy Keys** (generated during deployment)
   - `github_deploy_key_backend` - Private SSH key for backend repo
   - `github_deploy_key_backend.pub` - Public SSH key for backend repo
   - `github_deploy_key_frontend` - Private SSH key for frontend repo
   - `github_deploy_key_frontend.pub` - Public SSH key for frontend repo

2. **Webhook Secret** (generated during deployment)
   - `webhook_secret.txt` - GitHub webhook HMAC secret

⚠️ **IMPORTANT**: Never commit these files to version control!

These files are generated automatically by the deployment script.