// The one page the Worker renders: what a customer sees after paying.

const style = `
  :root { color-scheme: light dark; }
  body { margin: 0; background: #F8F7F3; color: #1B1B22; font: 400 17px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  @media (prefers-color-scheme: dark) { body { background: #121319; color: #ECECF1; } .code { background: #1A1B23; border-color: #272835; } .muted { color: #9496A6; } }
  .wrap { max-width: 520px; margin: 0 auto; padding: 72px 28px; }
  h1 { font-size: 34px; letter-spacing: -.03em; line-height: 1.08; margin: 0 0 16px; }
  p { margin: 0 0 18px; }
  .muted { color: #666878; font-size: 15px; }
  .button { display: inline-block; background: #5B63D3; color: #fff; text-decoration: none; font-weight: 600; padding: 13px 22px; border-radius: 11px; }
  .code { font: 500 14px/1.5 ui-monospace, Menlo, monospace; word-break: break-all; padding: 12px 14px; border: 1px solid #E6E4DE; border-radius: 10px; background: #fff; margin: 8px 0 18px; }
`;

function shell(title: string, body: string): Response {
  return new Response(
    `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${title}</title><style>${style}</style></head><body><div class="wrap">${body}</div></body></html>`,
    { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } },
  );
}

export function activatedPage(token: string): Response {
  const link = `relay://activate?token=${encodeURIComponent(token)}`;
  return shell("Relay Hosted is on", `
    <h1>Relay Hosted is on.</h1>
    <p>Open Relay to finish. It will pick up your account and start using it straight away.</p>
    <p><a class="button" href="${link}">Open Relay</a></p>
    <p class="muted">If the button does nothing, paste this activation code into Relay's Settings under Relay Hosted. Keep it private; it is the key to your account.</p>
    <div class="code">${token}</div>
    <p class="muted">This code is shown once. You can manage billing any time from Relay's Settings.</p>
  `);
}

export function alreadyActivatedPage(): Response {
  return shell("Already activated", `
    <h1>This purchase is already set up.</h1>
    <p>The activation code for it was shown once and is not kept. If you need Relay Hosted on another Mac, open Relay's Settings on the Mac that has it and use <strong>Add another Mac</strong>.</p>
    <p class="muted">Lost access entirely? Reply to your Stripe receipt and we will sort it out.</p>
  `);
}

export function notPaidPage(): Response {
  return shell("Not finished", `
    <h1>The payment did not go through.</h1>
    <p>Nothing was charged. You can try again from Relay's Settings.</p>
  `);
}
