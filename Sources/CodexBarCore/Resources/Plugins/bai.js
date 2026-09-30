defineProvider({
  id: "bai",
  name: "B.AI",
  endpoints: ["https://api.b.ai"],
  auth: { type: "bearer", secret: "BAI_API_KEY" },
  settings: [{ key: "BAI_API_KEY", title: "B.AI API key", type: "secure" }],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const response = await ctx.http.get("https://api.b.ai/v1/balance");
    const message = `B.AI returned HTTP ${response.status}.`;
    if (response.status === 401) throw ctx.fail.authenticationExpired(message);
    if (response.status === 403) throw ctx.fail.permissionDenied(message);
    if (response.status === 429) {
      const delay = Number(response.headers["retry-after"] ?? 1);
      throw ctx.fail.rateLimited(message, {
        retryAfterSeconds: Number.isFinite(delay) && delay >= 0 ? Math.min(delay, 10) : 1,
      });
    }
    if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
    if (response.status !== 200) throw ctx.fail.apiFailure(message);
    function fail() {
      throw ctx.fail.parseFailure("B.AI returned an unrecognized balance or quota response.");
    }
    const record = (value) => (value && typeof value === "object" && !Array.isArray(value) ? value : undefined);
    const credits = (value) => (typeof value === "number" && Number.isSafeInteger(value) ? value : fail());
    const quota = (value) => (credits(value) >= 0 ? value : fail());
    const format = (value) => `${ctx.format.number(value)} Credits`;
    let decoded;
    try {
      decoded = JSON.parse(response.bodyText);
    } catch {
      return fail();
    }
    const root = record(decoded);
    if (root?.success === false) throw ctx.fail.apiFailure("B.AI could not retrieve the balance.");
    const data = record(root?.data);
    if (root?.success !== true || !data) return fail();
    if (data.api_key_type === "personal") {
      return {
        details: [
          {
            title: "Personal balance",
            rows: [{ label: "Available balance", value: format(credits(data.personal_balance)) }],
          },
        ],
        identity: { loginMethod: "Personal API key" },
        dataConfidence: "exact",
      };
    }
    const team = record(data.team);
    if (data.api_key_type !== "team" || !team) return fail();
    if (team.quota_limit_type !== "limited" && team.quota_limit_type !== "unlimited") return fail();
    const used = quota(team.member_quota_used);
    const rows = [{ label: "Member quota used", value: format(used) }];
    let resetsAt;
    if (typeof team.quota_reset_at === "string") {
      const reset = new Date(team.quota_reset_at);
      if (Number.isFinite(reset.getTime())) resetsAt = reset.toISOString();
    }
    let primary;
    if (team.quota_limit_type === "limited") {
      const limit = quota(team.member_quota_limit);
      rows.push({ label: "Member quota limit", value: format(limit) });
      rows.push({ label: "Member quota remaining", value: format(Math.max(0, limit - used)) });
      primary = { usedPercent: ctx.pct(used, limit), resetsAt };
    } else {
      rows.push({ label: "Member quota limit", value: "Unlimited" });
    }
    if (resetsAt) rows.push({ label: "Quota reset", value: resetsAt });
    if (team.team_balance !== undefined)
      rows.push({ label: "Team balance", value: format(credits(team.team_balance)) });
    return {
      primary,
      details: [{ title: "Team quota", rows }],
      identity: { loginMethod: "Team API key" },
      dataConfidence: "exact",
    };
  },
});
