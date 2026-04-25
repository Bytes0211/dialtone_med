# Agent Instructions

## PR Review Comment Handling
- When asked to address PR review comments, always post a reply comment on the PR summarizing what was changed and how it was validated.
- Do not assume code changes alone are sufficient; leave an explicit PR thread response unless the user says not to.
- Do not merge or close a PR unless explicitly asked.

## Branching & Commits
- Never commit directly to `main`. Always create a feature branch.
- Do not stage or commit changes unless the user explicitly asks for a commit.
- When creating a commit message at the user's request, follow Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`, etc.).

## Project Layout
- Static assets are served from `public/` (matched by `wrangler.toml` `[assets].directory`).
- The Cloudflare Worker entry point is `worker.js`. It owns dynamic paths listed under `run_worker_first` in `wrangler.toml` — most importantly `/api/contact`, which forwards form submissions to Resend.
- Brand guidelines live in `docs/dialtone_med_brand_kit.pdf`. Cosmetic UI changes must adhere to the palette, type scale, spacing, and accessibility rules defined there.

## Secrets
- `RESEND_API_KEY` is a Worker secret (never committed). Set it via `npx wrangler secret put RESEND_API_KEY`.
- `CONTACT_EMAIL` and `SITE_NAME` are non-secret `[vars]` in `wrangler.toml`.
