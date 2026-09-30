---
summary: "B.AI personal credit balances and team member quotas through the balance API."
read_when:
  - Configuring B.AI
  - Debugging B.AI balance or quota data
---

# B.AI

B.AI is disabled by default. Add an API key in Settings → Providers → B.AI, or set `BAI_API_KEY`.
The setting is saved in CodexBar's local config file. The bundled `bai.js` plugin sends the key only to
`https://api.b.ai` as `Authorization: Bearer …` and reads `GET /v1/balance`. It uses no browser cookies or login flow.

Personal keys show `data.personal_balance`. Team keys show `data.team.member_quota_used`, and limited quotas also
show `member_quota_limit`, remaining quota, and a percentage. A valid `quota_reset_at` supplies the reset time.
`team_balance` appears only when the API returns it for an administrator. Personal and team balances remain separate.
All amounts are integer **Credits**, not USD. Zero and negative balances are preserved.

An explicit `quota_limit_type: "unlimited"` shows **Unlimited**, without inventing a percentage or remaining quota.
A limited quota of zero is exhausted, not unlimited. Missing or malformed required fields fail the refresh;
an HTTP 200 response with `success: false` is an API failure. Optional invalid reset times are omitted.

Successful snapshots use the app's existing refresh and cache behavior. HTTP 429 is classified as rate limiting,
with `Retry-After` bounded by the shared host's retry policy. No additional polling loop is introduced.
Like other bundled plugin providers, B.AI is not selectable in widgets.

```sh
codexbar usage --provider bai --source api --json
```

Source: [B.AI Balance API](https://docs.b.ai/llmservice/api/balance/), checked September 30, 2026.
Tests use documented response shapes with synthetic account data and mocked transport; live account behavior is unverified.
