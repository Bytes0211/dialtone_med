# Deployment Guide — DialTone.Med

Stack: Cloudflare Workers + Static Assets, Supabase (PostgreSQL), Resend (email)
Worker name: dialtone-med
Production URL: https://dialtone.med

---

## One-Time Setup

Complete these steps once when setting up a fresh environment.

### 1) Set Cloudflare Worker secrets

Run:

```bash
bash developer/ci/deploy-prod-secrets.sh
```

This uploads:
- RESEND_API_KEY
- SUPABASE_SERVICE_ROLE_KEY (preferred)
- SUPABASE_KEY (fallback)

Verify:

```bash
npx wrangler secret list
```

### 2) Run the Supabase schema migration

In Supabase SQL Editor, run:

```sql
-- paste file contents from:
developer/supabase/01_waitlist_schema.sql
```

This creates/updates `waitlist_submissions`, applies backfills, and ensures required RLS policies and indexes exist.

### 3) Add GitHub Actions secrets

In GitHub: Repository -> Settings -> Secrets and variables -> Actions

Add:
- CLOUDFLARE_API_TOKEN
- CLOUDFLARE_ACCOUNT_ID

### 4) Confirm wrangler vars

In wrangler.toml under [vars], verify:
- CONTACT_EMAIL is correct
- SITE_NAME = DialTone.Med
- SUPABASE_URL points to the intended project

---

## Every Deploy

### 5) Run local preflight checks

```bash
pnpm install --frozen-lockfile
node --check worker.js
test -f public/index.html
test -f public/404.html
test -f public/privacy.html
test -f public/terms.html
```

### 6) Review changes

```bash
git status
git diff
```

### 7) Push branch and open PR

```bash
git push origin <your-branch>
```

Open a pull request to main.

### 8) Merge PR to main

On merge, GitHub Actions workflow `.github/workflows/deploy.yml` runs:
1. Preflight checks (worker syntax + static-file smoke checks)
2. Dependency install
3. Cloudflare deploy (`pnpm wrangler deploy`)

---

## Post-Deploy Smoke Test

After deploy is green:
1. Open https://dialtone.med and confirm page load
2. Submit the contact form
3. Confirm all outcomes:
   - POST /api/contact returns 200 OK
   - row is inserted into Supabase `waitlist_submissions`
   - email arrives at CONTACT_EMAIL

Example query:

```sql
select id, name, company_name, restaurant_name, email, campaign, created_at
from public.waitlist_submissions
order by created_at desc
limit 10;
```

---

## Secret Rotation

Rotate all configured secrets:

```bash
bash developer/ci/deploy-prod-secrets.sh
```

Rotate one secret:

```bash
npx wrangler secret put RESEND_API_KEY
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Form returns 503 | Missing SUPABASE_URL or Supabase key | Verify wrangler.toml vars and `wrangler secret list` |
| Form returns 502 | Supabase insert failure / schema drift | Re-run `developer/supabase/01_waitlist_schema.sql` |
| Email not sent but row saved | RESEND_API_KEY missing/invalid | Rotate RESEND_API_KEY and retest |
| CI fails preflight | Syntax or required file missing | Run local preflight commands and fix |
| robots/sitemap issues | Config drift in worker routing | Verify `/robots.txt` and `/sitemap.xml` from deployed site |

---

## Related Files

| File | Purpose |
|---|---|
| wrangler.toml | Worker config, vars, assets, dynamic route ownership |
| worker.js | API and asset routing, sitemap/robots generation, Supabase + Resend logic |
| .github/workflows/deploy.yml | CI preflight + deploy workflow |
| developer/ci/deploy-prod-secrets.sh | Interactive production secret uploader |
| developer/supabase/01_waitlist_schema.sql | Supabase schema + migration/backfill script |
| developer/supabase/setup-supabase.sh | Supabase setup helper |
