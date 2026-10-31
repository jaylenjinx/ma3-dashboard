#!/usr/bin/env node
// Writes portainer-stack.yml: a compose file with server.js embedded, so it can be pasted into Portainer's
// web editor (Stacks → Add stack) with no image to build or registry to push to. Re-run after editing server.js.
const fs = require('fs');
const path = require('path');

const src = fs.readFileSync(path.join(__dirname, 'server.js'), 'utf8').replace(/\s+$/, '');
const EOF = 'MA_SYNC_SERVER_EOF';
if (src.includes(EOF)) throw new Error(`server.js contains the heredoc marker ${EOF}`);

// Compose interpolates $VAR inside the file, so every literal $ in the script is written as $$.
const indent = (text, n) => text.split('\n').map(l => (l ? ' '.repeat(n) + l : '')).join('\n');
const script = [
  `cat > /tmp/server.js <<'${EOF}'`,
  src,
  EOF,
  '# The named volume starts out owned by root; give it to the node user, then drop to that user.',
  'chown -R node:node /data',
  `exec node -e "process.setgid('node'); process.setuid('node'); require('/tmp/server.js')"`,
].join('\n').replace(/\$/g, '$$$$');

const yml = `# MA Dashboard sync server, for Portainer: Stacks → Add stack → Web editor, paste this file,
# then add the environment variables SYNC_TOKEN and TUNNEL_TOKEN (see README.md).
# Generated from server.js by build-portainer-stack.js; edit that, not this.
services:
  sync:
    image: node:22-alpine
    restart: unless-stopped
    user: "0"
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
${indent(script, 8)}
    environment:
      SYNC_TOKEN: \${SYNC_TOKEN:?set SYNC_TOKEN}
      KEEP_VERSIONS: \${KEEP_VERSIONS:-10}
      DATA_DIR: /data
      PORT: "8787"
    volumes:
      - ma-sync-data:/data
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8787/api/health"]
      interval: 30s
      timeout: 5s
    # Uncomment to reach the server on your LAN without the tunnel:
    # ports:
    #   - "8787:8787"

  # Delete this service if you only use the server on your LAN.
  tunnel:
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    environment:
      TUNNEL_TOKEN: \${TUNNEL_TOKEN:?set TUNNEL_TOKEN}
    depends_on:
      - sync

volumes:
  ma-sync-data:
`;
fs.writeFileSync(path.join(__dirname, 'portainer-stack.yml'), yml);
console.log(`Wrote portainer-stack.yml (${yml.length} bytes)`);
