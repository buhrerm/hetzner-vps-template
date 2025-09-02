import { createHmac } from 'crypto';
import { $ } from 'bun';

const WEBHOOK_SECRET = process.env.GITHUB_WEBHOOK_SECRET || '';
const PORT = 9000;

// Configuration - customize these for your repos
const REPO_CONFIG = {
  // Map your GitHub repository names to service names and paths
  // Example: 'MyAppBackend': { service: 'api', path: '/opt/MyAppBackend' }
  [process.env.BACKEND_REPO_NAME || 'Backend']: { 
    service: 'api', 
    path: `/opt/${process.env.BACKEND_REPO_NAME || 'Backend'}` 
  },
  [process.env.FRONTEND_REPO_NAME || 'Frontend']: { 
    service: 'frontend', 
    path: `/opt/${process.env.FRONTEND_REPO_NAME || 'Frontend'}` 
  }
};

// Verify GitHub webhook signature
function verifySignature(payload: string, signature: string): boolean {
  const hmac = createHmac('sha256', WEBHOOK_SECRET);
  const digest = 'sha256=' + hmac.update(payload).digest('hex');
  
  // Timing-safe comparison
  if (signature.length !== digest.length) return false;
  
  let result = 0;
  for (let i = 0; i < signature.length; i++) {
    result |= signature.charCodeAt(i) ^ digest.charCodeAt(i);
  }
  return result === 0;
}

// Deploy function
async function deploy(repo: string, branch: string) {
  console.log(`Deploying ${repo} from ${branch} branch...`);
  
  try {
    // Find repository configuration
    const config = REPO_CONFIG[repo];
    if (!config) {
      // Try case-insensitive match
      const repoKey = Object.keys(REPO_CONFIG).find(key => 
        key.toLowerCase() === repo.toLowerCase()
      );
      
      if (!repoKey) {
        throw new Error(`Unknown repository: ${repo}`);
      }
      
      Object.assign(config, REPO_CONFIG[repoKey]);
    }
    
    const { service: serviceName, path: repoPath } = config;
    
    // Pull latest code
    console.log(`Pulling latest code for ${serviceName}...`);
    await $`cd ${repoPath} && git pull origin ${branch}`;
    
    // Run migrations if it's the API
    if (serviceName === 'api') {
      console.log('Running database migrations...');
      await $`cd /opt/deployment && /usr/bin/docker compose run --rm api bunx prisma migrate deploy`;
    }
    
    // Restart the service with zero-downtime using docker-compose
    console.log(`Restarting ${serviceName} service...`);
    await $`cd /opt/deployment && /usr/bin/docker compose up -d --no-deps --build ${serviceName}`;
    
    // Health check
    console.log('Waiting for service to be healthy...');
    await Bun.sleep(10000); // Wait 10 seconds
    
    const healthEndpoint = serviceName === 'api' 
      ? 'http://api:4000/health' 
      : 'http://frontend:3000';
    
    try {
      const response = await fetch(healthEndpoint);
      if (!response.ok) {
        throw new Error(`Health check failed: ${response.status}`);
      }
    } catch (error) {
      console.warn('Health check failed, but service may still be running');
    }
    
    console.log(`✅ Successfully deployed ${serviceName}`);
    return { success: true, message: `Deployed ${serviceName} successfully` };
    
  } catch (error: any) {
    console.error(`❌ Deployment failed: ${error}`);
    
    // Rollback on failure
    const config = REPO_CONFIG[repo];
    if (config) {
      try {
        console.log('Attempting rollback...');
        await $`cd /opt/deployment && /usr/bin/docker compose up -d --no-deps ${config.service}`.quiet();
      } catch (rollbackError) {
        console.error('Rollback failed:', rollbackError);
      }
    }
    
    return { success: false, message: `Deployment failed: ${error}` };
  }
}

// Start webhook server
Bun.serve({
  port: PORT,
  async fetch(req) {
    const url = new URL(req.url);
    
    // Health check endpoint
    if (url.pathname === '/health') {
      return new Response('OK', { status: 200 });
    }
    
    // Only accept POST requests to root path
    if (req.method !== 'POST' || url.pathname !== '/') {
      return new Response('Not Found', { status: 404 });
    }
    
    // Verify GitHub signature
    const signature = req.headers.get('X-Hub-Signature-256') || '';
    const event = req.headers.get('X-GitHub-Event') || '';
    const delivery = req.headers.get('X-GitHub-Delivery') || '';
    
    let body = await req.text();
    
    // Handle form-urlencoded payloads from GitHub
    let payload: any;
    const contentType = req.headers.get('Content-Type') || '';
    
    if (contentType.includes('application/x-www-form-urlencoded')) {
      // Parse form data
      const params = new URLSearchParams(body);
      const payloadStr = params.get('payload') || '{}';
      payload = JSON.parse(payloadStr);
      // Use the raw payload string for signature verification
      body = payloadStr;
    } else {
      // Parse JSON directly
      payload = JSON.parse(body);
    }
    
    if (!verifySignature(body, signature)) {
      console.error('Invalid signature');
      return new Response('Unauthorized', { status: 401 });
    }
    
    console.log(`Received ${event} event (delivery: ${delivery})`);
    
    // Only process push events to main/master branch
    if (event === 'push' && (payload.ref === 'refs/heads/main' || payload.ref === 'refs/heads/master')) {
      const repo = payload.repository.name;
      const branch = payload.ref.split('/').pop();
      
      // Deploy asynchronously
      deploy(repo, branch).then(result => {
        console.log('Deployment result:', result);
      });
      
      return new Response(JSON.stringify({ 
        message: 'Deployment started',
        repository: repo,
        branch: branch
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' }
      });
    }
    
    // Respond to ping events
    if (event === 'ping') {
      return new Response(JSON.stringify({ message: 'pong' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' }
      });
    }
    
    return new Response(JSON.stringify({ 
      message: 'Event ignored',
      event: event,
      ref: payload.ref
    }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' }
    });
  },
});

console.log(`🚀 Webhook server running on port ${PORT}`);
console.log(`Webhook secret is ${WEBHOOK_SECRET ? 'configured' : 'NOT configured'}`);
console.log('Configured repositories:', Object.keys(REPO_CONFIG));