import type { Env } from "./env";
import { json, problem } from "./env";
import { resolveToken, type Principal } from "./auth";
import { equalSecrets, seal } from "./crypto";
import { shell } from "./pages";
import { audit, DEFAULT_MEMBER_CAP_CENTS, membersWithUsage, orgById, orgDomains, revokeMemberDevices, setOrgKey, type Org } from "./orgs";
import { monthKey } from "./pricing";

// The admin console: one page, a few forms. Signed into with the same SSO as
// the app; the browser holds a short-lived device token in a cookie.

const COOKIE = "relay_admin";

export function adminCookie(token: string): string {
  return `${COOKIE}=${token}; Path=/admin; HttpOnly; Secure; SameSite=Lax; Max-Age=86400`;
}

async function adminPrincipal(request: Request, env: Env): Promise<Extract<Principal, { kind: "member" }> | null> {
  const cookie = request.headers.get("cookie") ?? "";
  const match = cookie.match(new RegExp(`(?:^|;\\s*)${COOKIE}=([^;]+)`));
  if (!match) return null;
  const who = await resolveToken(decodeURIComponent(match[1]), env);
  return who && who.kind === "member" && who.role === "admin" ? who : null;
}

/** One-time: creates an org, its domains and its IdP. Guarded by BOOTSTRAP_SECRET. */
export async function bootstrap(request: Request, env: Env): Promise<Response> {
  const header = request.headers.get("authorization") ?? "";
  if (!env.BOOTSTRAP_SECRET || !equalSecrets(header, `Bearer ${env.BOOTSTRAP_SECRET}`)) return problem(401, "Bootstrap secret required.");

  const body = (await request.json()) as {
    id: string; name: string; domains: string[];
    idp: { issuer: string; clientId: string; clientSecret: string };
    adminEmails?: string[]; localModel?: string;
  };
  if (!/^[a-z0-9-]{2,32}$/.test(body.id ?? "")) return problem(400, "id must be a short slug.");
  if (!body.name || !body.domains?.length || !body.idp?.issuer || !body.idp?.clientId || !body.idp?.clientSecret) return problem(400, "name, domains and idp are required.");

  const now = Date.now();
  const secret = await seal(body.idp.clientSecret, env.ORG_KEK);
  const statements = [
    env.DB.prepare("INSERT INTO orgs (id, name, local_model, admin_emails, member_cap_cents, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)")
      .bind(body.id, body.name, body.localModel ?? "gpt-5.6-luna", JSON.stringify((body.adminEmails ?? []).map((e) => e.toLowerCase())), DEFAULT_MEMBER_CAP_CENTS, now, now),
    env.DB.prepare("INSERT INTO org_idps (org_id, issuer, client_id, client_secret_ciphertext, client_secret_iv) VALUES (?, ?, ?, ?, ?)")
      .bind(body.id, body.idp.issuer.replace(/\/$/, ""), body.idp.clientId, secret.ciphertext, secret.iv),
    ...body.domains.map((d) => env.DB.prepare("INSERT INTO org_domains (domain, org_id) VALUES (?, ?)").bind(d.toLowerCase(), body.id)),
  ];
  await env.DB.batch(statements);
  await audit(env, body.id, "bootstrap", "org.created", body.domains.join(","));
  return json({ ok: true, org: body.id, signIn: `${new URL(request.url).origin}/auth/start?purpose=admin&email=admin@${body.domains[0]}` });
}

/** GET /admin and everything under it. */
export async function admin(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname === "/admin/login") return loginPage();

  const who = await adminPrincipal(request, env);
  if (!who) return Response.redirect(`${url.origin}/admin/login`, 302);
  const org = await orgById(env, who.orgId);
  if (!org) return problem(404, "No such org.");

  const route = `${request.method} ${url.pathname}`;
  if (route === "GET /admin") return consolePage(env, org, who, url.searchParams.get("month") ?? monthKey(), url.searchParams.get("saved"));
  if (route === "GET /admin/usage.csv") return usageCSV(env, org, url.searchParams.get("month") ?? monthKey());
  if (route === "POST /admin/keys") return saveKeys(request, env, org, who);
  if (route === "POST /admin/settings") return saveSettings(request, env, org, who);
  if (route === "POST /admin/member") return memberAction(request, env, org, who);
  return problem(404, "No such page.");
}

const consoleStyle = `
  .wrap { max-width: 860px; }
  h2 { font-size: 20px; margin: 36px 0 10px; }
  form { margin: 0; }
  label { display: block; font-size: 14px; color: #666878; margin: 12px 0 4px; }
  input[type=text], input[type=password], input[type=number], select { width: 100%; max-width: 420px; font: inherit; font-size: 15px; padding: 8px 10px; border: 1px solid #E6E4DE; border-radius: 8px; background: #fff; color: inherit; }
  @media (prefers-color-scheme: dark) { input[type=text], input[type=password], input[type=number], select { background: #1A1B23; border-color: #272835; } th { background: #1A1B23 !important; } tr:nth-child(even) td { background: #16171f; } }
  .row { display: flex; gap: 18px; flex-wrap: wrap; align-items: center; }
  .check { display: flex; gap: 8px; align-items: center; font-size: 15px; margin: 8px 0; }
  button, .btn { font: inherit; font-size: 14px; font-weight: 600; padding: 9px 16px; border-radius: 9px; border: 0; background: #5B63D3; color: #fff; cursor: pointer; margin-top: 12px; }
  button.quiet { background: transparent; color: #5B63D3; padding: 4px 6px; margin: 0; font-weight: 500; }
  table { width: 100%; border-collapse: collapse; font-size: 14px; margin-top: 8px; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid #E6E4DE; }
  th { font-size: 12px; letter-spacing: .05em; text-transform: uppercase; color: #8E909D; background: #fff; }
  td.num { text-align: right; font-variant-numeric: tabular-nums; }
  th.num { text-align: right; }
  .saved { background: rgba(89,169,122,.15); color: #2f7a52; padding: 8px 12px; border-radius: 8px; font-size: 14px; display: inline-block; }
  .pill { font-size: 11px; letter-spacing: .05em; text-transform: uppercase; padding: 2px 6px; border-radius: 5px; background: rgba(91,99,211,.12); color: #5B63D3; margin-left: 6px; }
`;

function esc(text: string | null | undefined): string {
  return (text ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

function loginPage(): Response {
  return shell("Relay admin", `
    <h1>Relay admin</h1>
    <p>Sign in with your work account. Only admins for your company's Relay can continue.</p>
    <form method="get" action="/auth/start">
      <input type="hidden" name="purpose" value="admin">
      <label>Work email</label>
      <input type="text" name="email" placeholder="you@company.com" autocomplete="email" required>
      <button type="submit">Continue</button>
    </form>
  `, consoleStyle);
}

async function consolePage(env: Env, org: Org, who: Extract<Principal, { kind: "member" }>, month: string, saved: string | null): Promise<Response> {
  const members = await membersWithUsage(env, org.id, month);
  const domains = await orgDomains(env, org.id);
  const totalLocal = members.reduce((s, m) => s + m.localMinutes, 0);
  const totalInstant = members.reduce((s, m) => s + Math.round(m.instantSeconds / 60), 0);
  const when = (t: number) => (t ? new Date(t).toISOString().slice(0, 10) : "never");
  const months = Array.from({ length: 6 }, (_, i) => { const d = new Date(); d.setUTCMonth(d.getUTCMonth() - i); return monthKey(d); });

  const rows = members.map((m) => `
    <tr>
      <td>${esc(m.email)}${m.role === "admin" ? '<span class="pill">admin</span>' : ""}${m.status !== "active" ? '<span class="pill">suspended</span>' : ""}</td>
      <td>${esc(m.name)}</td>
      <td>${when(m.lastSeen)}</td>
      <td class="num">${m.localMinutes}</td>
      <td class="num">${Math.round(m.instantSeconds / 60)}</td>
      <td class="num">${m.devices}</td>
      <td>
        <form method="post" action="/admin/member" style="display:inline">
          <input type="hidden" name="id" value="${esc(m.id)}">
          <button class="quiet" name="action" value="signout" type="submit">Sign out everywhere</button>
          ${m.status === "active" ? '<button class="quiet" name="action" value="suspend" type="submit">Suspend</button>' : '<button class="quiet" name="action" value="restore" type="submit">Restore</button>'}
          ${m.role === "admin" ? '<button class="quiet" name="action" value="demote" type="submit">Make member</button>' : '<button class="quiet" name="action" value="promote" type="submit">Make admin</button>'}
        </form>
      </td>
    </tr>`).join("");

  return shell(`${org.name} · Relay admin`, `
    <h1>${esc(org.name)}</h1>
    <p class="muted">Signed in as ${esc(who.email)}. Domains: ${domains.map(esc).join(", ")}. Relay stores minutes, members and devices; never what anyone said.</p>
    ${saved ? `<p class="saved">Saved.</p>` : ""}

    <h2>Usage</h2>
    <form method="get" action="/admin" class="row">
      <label style="margin:0">Month</label>
      <select name="month" onchange="this.form.submit()">${months.map((m) => `<option ${m === month ? "selected" : ""}>${m}</option>`).join("")}</select>
      <a class="btn" style="margin:0" href="/admin/usage.csv?month=${month}">Download CSV</a>
    </form>
    <p class="muted">${members.length} people · ${totalLocal} Local minutes · ${totalInstant} Instant minutes this month.</p>
    <table>
      <thead><tr><th>Person</th><th>Name</th><th>Last seen</th><th class="num">Local min</th><th class="num">Instant min</th><th class="num">Macs</th><th></th></tr></thead>
      <tbody>${rows || '<tr><td colspan="7" class="muted">Nobody has signed in yet.</td></tr>'}</tbody>
    </table>

    <h2>Provider keys</h2>
    <p class="muted">Stored encrypted and used only on the server. Leave a field blank to keep the current key; tick Remove to clear it.</p>
    <form method="post" action="/admin/keys">
      <label>OpenAI key ${org.hasOpenAI ? '<span class="pill">set</span>' : '<span class="pill">not set</span>'}</label>
      <input type="password" name="openai" placeholder="sk-…" autocomplete="off">
      <div class="check"><input type="checkbox" name="openai_clear" id="oc"><label for="oc" style="margin:0">Remove the OpenAI key</label></div>
      <label>Anthropic key ${org.hasAnthropic ? '<span class="pill">set</span>' : '<span class="pill">not set</span>'}</label>
      <input type="password" name="anthropic" placeholder="sk-ant-…" autocomplete="off">
      <div class="check"><input type="checkbox" name="anthropic_clear" id="ac"><label for="ac" style="margin:0">Remove the Anthropic key</label></div>
      <button type="submit">Save keys</button>
    </form>

    <h2>Settings</h2>
    <form method="post" action="/admin/settings">
      <label>Local mode model</label>
      <select name="local_model">
        ${["gpt-5.6-luna", "gpt-5.6-terra", "claude-haiku-4-5", "claude-sonnet-5"].map((m) => `<option ${m === org.localModel ? "selected" : ""}>${m}</option>`).join("")}
      </select>
      <p class="muted" style="font-size:13px">Claude models use the Anthropic key; GPT models use the OpenAI key. Instant mode always needs the OpenAI key.</p>
      <div class="check"><input type="checkbox" name="allowInstant" id="ai" ${org.policy.allowInstant ? "checked" : ""}><label for="ai" style="margin:0">Allow Instant mode (audio streams to OpenAI)</label></div>
      <div class="check"><input type="checkbox" name="allowTranscript" id="at" ${org.policy.allowTranscript ? "checked" : ""}><label for="at" style="margin:0">Allow keeping a transcript</label></div>
      <div class="check"><input type="checkbox" name="allowMicrophone" id="am" ${org.policy.allowMicrophone ? "checked" : ""}><label for="am" style="margin:0">Allow the microphone as a source</label></div>
      <label>Per-person monthly limit, in dollars at list rates (0 for none)</label>
      <input type="number" name="member_cap" min="0" step="1" value="${org.memberCapCents / 100}">
      <label>Company monthly limit, in dollars (0 for none)</label>
      <input type="number" name="org_cap" min="0" step="1" value="${org.orgCapCents / 100}">
      <label>Days before someone must sign in again</label>
      <input type="number" name="reauth_days" min="1" max="365" value="${org.reauthDays}">
      <button type="submit">Save settings</button>
    </form>
  `, consoleStyle);
}

async function saveKeys(request: Request, env: Env, org: Org, who: Extract<Principal, { kind: "member" }>): Promise<Response> {
  const form = await request.formData();
  for (const provider of ["openai", "anthropic"] as const) {
    const value = String(form.get(provider) ?? "").trim();
    const clear = form.get(`${provider}_clear`) === "on";
    if (clear) { await setOrgKey(env, org.id, provider, null); await audit(env, org.id, who.email, `${provider}.key.removed`); }
    else if (value) { await setOrgKey(env, org.id, provider, value); await audit(env, org.id, who.email, `${provider}.key.set`); }
  }
  return Response.redirect(`${new URL(request.url).origin}/admin?saved=1`, 303);
}

async function saveSettings(request: Request, env: Env, org: Org, who: Extract<Principal, { kind: "member" }>): Promise<Response> {
  const form = await request.formData();
  const model = String(form.get("local_model") ?? org.localModel);
  const policy = {
    allowInstant: form.get("allowInstant") === "on",
    allowTranscript: form.get("allowTranscript") === "on",
    allowMicrophone: form.get("allowMicrophone") === "on",
  };
  const memberCap = Math.max(0, Math.round(Number(form.get("member_cap") ?? 0) * 100));
  const orgCap = Math.max(0, Math.round(Number(form.get("org_cap") ?? 0) * 100));
  const reauth = Math.min(365, Math.max(1, Math.round(Number(form.get("reauth_days") ?? 30))));
  await env.DB.prepare("UPDATE orgs SET local_model = ?, policy_json = ?, member_cap_cents = ?, org_cap_cents = ?, reauth_days = ?, updated_at = ? WHERE id = ?")
    .bind(model, JSON.stringify(policy), memberCap, orgCap, reauth, Date.now(), org.id).run();
  await audit(env, org.id, who.email, "settings.saved", JSON.stringify({ model, policy, memberCap, orgCap, reauth }));
  return Response.redirect(`${new URL(request.url).origin}/admin?saved=1`, 303);
}

async function memberAction(request: Request, env: Env, org: Org, who: Extract<Principal, { kind: "member" }>): Promise<Response> {
  const form = await request.formData();
  const id = String(form.get("id") ?? "");
  const action = String(form.get("action") ?? "");
  const target = await env.DB.prepare("SELECT id, email FROM members WHERE id = ? AND org_id = ?").bind(id, org.id).first<{ id: string; email: string }>();
  if (!target) return problem(404, "No such member.");

  switch (action) {
    case "signout": await revokeMemberDevices(env, id); break;
    case "suspend": await env.DB.prepare("UPDATE members SET status = 'suspended' WHERE id = ?").bind(id).run(); await revokeMemberDevices(env, id); break;
    case "restore": await env.DB.prepare("UPDATE members SET status = 'active' WHERE id = ?").bind(id).run(); break;
    case "promote": await env.DB.prepare("UPDATE members SET role = 'admin' WHERE id = ?").bind(id).run(); break;
    case "demote":
      if (id === who.memberId) return problem(400, "You cannot remove your own admin role.");
      await env.DB.prepare("UPDATE members SET role = 'member' WHERE id = ?").bind(id).run(); break;
    default: return problem(400, "Unknown action.");
  }
  await audit(env, org.id, who.email, `member.${action}`, target.email);
  return Response.redirect(`${new URL(request.url).origin}/admin?saved=1`, 303);
}

async function usageCSV(env: Env, org: Org, month: string): Promise<Response> {
  const { results } = await env.DB.prepare(`
    SELECT u.day, m.email, m.name, u.local_minutes, u.instant_seconds
      FROM usage_daily u JOIN members m ON m.id = u.member_id
     WHERE u.org_id = ? AND u.day LIKE ?
     ORDER BY u.day, m.email`,
  ).bind(org.id, `${month}-%`).all<{ day: string; email: string; name: string | null; local_minutes: number; instant_seconds: number }>();
  const q = (s: string | null) => `"${(s ?? "").replace(/"/g, '""')}"`;
  const lines = ["day,email,name,local_minutes,instant_minutes",
    ...results.map((r) => `${r.day},${q(r.email)},${q(r.name)},${r.local_minutes},${(r.instant_seconds / 60).toFixed(1)}`)];
  return new Response(lines.join("\n") + "\n", {
    headers: { "content-type": "text/csv; charset=utf-8", "content-disposition": `attachment; filename="relay-${org.id}-${month}.csv"` },
  });
}
