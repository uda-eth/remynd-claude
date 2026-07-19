# remynd-claude-install (Cloudflare Worker)

Serves the installer at **https://remyndai.com/claude/install.sh** by proxying the
canonical `install.sh` from this repo's `main`. Claims only `remyndai.com/claude/*`,
so it does not affect the founder landing page or the API worker.

## Deploy

```bash
CLOUDFLARE_API_TOKEN=<scoped: Edit Cloudflare Workers on the Move37 account> \
  npx --yes wrangler deploy
```

Account: `Move37 DNS` (7f1947c685df6d855f9f87331cd8a72a) · Zone: `remyndai.com`.
