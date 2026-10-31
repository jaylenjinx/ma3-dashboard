# MA Dashboard sync server

A small file store that MA3 Dashboard syncs showfiles and library files to. It's one Node file with no dependencies. It runs in Docker and is reached over a Cloudflare Tunnel, so the server needs no open ports.

## What it stores

- `data/files/`: the current copy of every synced file, under product/version paths such as `ma3/2.5.1/shows/My Show.show`, `ma3/library/colorthemes/…` and `ma2/3.9.63/shows/…`. The paths don't depend on the platform, so a Windows client can use the same server.
- `data/versions/`: the previous `KEEP_VERSIONS` copies of each file (10 by default), including deleted files. Nothing a client overwrites or deletes is lost.
- `data/index.json`: a checksum and revision for every file.

## Setup with Portainer

`portainer-stack.yml` is a single compose file with the server built in. It uses the stock `node:22-alpine` image, so there's nothing to build and no registry to push to.

1. Create a Cloudflare tunnel (step 2 below), using the service URL `http://sync:8787`.
2. In Portainer, open Stacks → Add stack. Name it `ma-sync`, choose **Web editor**, and paste the contents of `portainer-stack.yml`.
3. Under **Environment variables**, add:
   - `SYNC_TOKEN`: a long random string (`openssl rand -hex 32`)
   - `TUNNEL_TOKEN`: the token from Cloudflare
   - `KEEP_VERSIONS` (optional): how many old copies to keep per file; the default is 10.
4. Click **Deploy the stack**. The `sync` container's log should read `MA sync server on :8787`.
5. In MA3 Dashboard → Cloud Sync, enter the tunnel's hostname and the `SYNC_TOKEN`.

For LAN-only use, delete the `tunnel` service in the editor and uncomment `ports`. The server will then be at `http://<server-ip>:8787`.

Files live in the `ma-sync-data` volume (Volumes in Portainer). To update the server after changing `server.js`, run `node build-portainer-stack.js`, paste the new file over the stack (Stacks → ma-sync → Editor), and click Update the stack. The data is kept.

## Setup with docker compose

1. Copy this folder to the server.
2. Create a tunnel in the Cloudflare dashboard (Zero Trust → Networks → Tunnels → Create, type Cloudflared). Give it a public hostname such as `masync.example.com` with service `http://sync:8787`. Copy the tunnel token.
3. Create `.env` next to `docker-compose.yml`:

   ```
   SYNC_TOKEN=<output of: openssl rand -hex 32>
   TUNNEL_TOKEN=<token from step 2>
   ```

4. Start it:

   ```
   docker compose up -d --build
   ```

5. In MA3 Dashboard → Cloud Sync, enter `https://masync.example.com` and the `SYNC_TOKEN`, then press Test Connection.

To skip the tunnel and use it only on your LAN, remove the `tunnel` service and uncomment `ports`.

## Notes

- Uploads are sent in 16 MB chunks because Cloudflare's free plan rejects request bodies over 100 MB. Large showfiles are fine.
- The token is the only protection. You can add Cloudflare Access in front of the hostname, but then use a service-token policy, because the app can't complete an interactive login.
- To back up, copy the `data/` folder.

## API

All endpoints except `/api/health` need `Authorization: Bearer <SYNC_TOKEN>`.

| Method | Path | Notes |
|---|---|---|
| GET | `/api/health` | `{ok, rev}` |
| GET | `/api/manifest` | `{rev, files: {path: {sha, size, mtime, rev, deleted?, device}}}` |
| POST | `/api/uploads` | Starts an upload, returns `{id}` |
| PUT | `/api/uploads/:id?offset=N` | Appends one chunk; `offset` must equal the bytes received so far |
| POST | `/api/uploads/:id/commit` | `{path, sha, mtime, baseSha?, device}`; returns 409 if `baseSha` isn't the server's current sha |
| GET | `/api/file?path=` | Downloads the current file (`X-SHA256` and `X-Mtime` headers) |
| DELETE | `/api/file?path=&baseSha=` | Archives the file and records a deletion |
| GET | `/api/versions?path=[&v=]` | Lists archived copies, or downloads one |
