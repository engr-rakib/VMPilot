"use strict";

// mailer.js — optional SMTP delivery for alerts. Opt-in: when no SMTP host is
// configured, every send is a no-op (bell/log still work). Config comes from
// the `alerting` settings row (alerts.getConfig().smtp).

const nodemailer = require("nodemailer");

let transporterCache = null;

function configured(cfg) {
  const s = (cfg && cfg.smtp) || {};
  return Boolean(s.host && s.from && s.to);
}

function transporter(cfg) {
  const s = cfg.smtp || {};
  if (transporterCache) return transporterCache;
  transporterCache = nodemailer.createTransport({
    host: s.host,
    port: Number(s.port || 587),
    secure: Boolean(s.secure),
    auth: s.user ? { user: s.user, pass: s.password || "" } : undefined,
    tls: { rejectUnauthorized: false }
  });
  return transporterCache;
}

function textFor(a, baseUrl) {
  const line = [
    `[VMPilot ${a.severity}] ${a.label}`,
    a.value ? `  value: ${a.value}` : "",
    `  target: ${[a.vc, a.env, a.vm].filter(Boolean).join(" / ") || "—"}`,
    `  at: ${new Date(a.at).toLocaleString()}`,
    baseUrl ? `  view in console: ${baseUrl}/#/events` : "  view in console → /events"
  ].filter(Boolean).join("\n");
  return line;
}

async function sendAlert(cfg, a, baseUrl = "") {
  if (!configured(cfg)) return { ok: true, skipped: true };
  try {
    const html = baseUrl ? [
      `<p><b>[VMPilot ${a.severity}] ${a.label}</b>${a.value ? " · " + a.value : ""}</p>`,
      `<p>target: ${[a.vc, a.env, a.vm].filter(Boolean).join(" / ") || "—"}<br>at: ${new Date(a.at).toLocaleString()}</p>`,
      `<p><a href="${baseUrl}/#/events">Open the VMPilot console →</a></p>`
    ].join("") : "";
    await transporter(cfg).sendMail({
      from: cfg.smtp.from,
      to: cfg.smtp.to,
      subject: `[VMPilot ${a.severity}] ${a.label}${a.vm ? " · " + a.vm : ""}`,
      text: textFor(a, baseUrl),
      ...(html ? { html } : {})
    });
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String((e && e.message) || e) };
  }
}

async function sendTest(cfg) {
  if (!configured(cfg)) return { ok: false, error: "SMTP not configured (host/from/to required)" };
  try {
    await transporter(cfg).sendMail({
      from: cfg.smtp.from,
      to: cfg.smtp.to,
      subject: "[VMPilot] Test notification",
      text: "This is a test notification from the VMPilot operator console.\n\nSMTP delivery is working."
    });
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String((e && e.message) || e) };
  }
}

module.exports = { sendAlert, sendTest, configured };