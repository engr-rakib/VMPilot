"use strict";

const fs = require("fs");
const path = require("path");

function intEnv(name, def) {
  const v = parseInt(process.env[name] || "", 10);
  return Number.isNaN(v) ? def : v;
}

// Docker Compose interpolates `$VAR` even inside .env values, which corrupts
// bcrypt hashes (they contain `$`). Secrets are therefore passed via a plain
// file that the app parses LITERALLY.
function loadSecretsFile(filepath) {
  try {
    const text = fs.readFileSync(filepath, "utf8");
    for (const line of text.split("\n")) {
      const t = line.trim();
      if (!t || t.startsWith("#")) continue;
      const i = t.indexOf("=");
      if (i < 0) continue;
      const key = t.slice(0, i).trim();
      const value = t.slice(i + 1).trim();
      if (!(key in process.env)) process.env[key] = value;
    }
  } catch {
    // file is optional when env vars are provided directly
  }
}

loadSecretsFile(process.env.WEBUI_SECRETS_FILE || "/run/secrets/webui.env");

module.exports = {
  port: intEnv("PORT", 3000),
  host: process.env.HOST || "0.0.0.0",
  user: process.env.WEBUI_USER || "admin",
  passHash: process.env.WEBUI_PASS_HASH || "",
  secret: process.env.WEBUI_SECRET || "",
  vmpilotDir: process.env.VMPILOT_DIR || "/vmpilot",
  dataDir: process.env.WEBUI_DATA_DIR || "/app/data",
  frontendDir: process.env.WEBUI_FRONTEND_DIR || "",
  terminalUid: intEnv("TERMINAL_UID", 1000),
  terminalGid: intEnv("TERMINAL_GID", 1000),
  terminalShell: process.env.TERMINAL_SHELL || "/bin/bash",
  sshKeyPath: process.env.WEBUI_SSH_KEY || "/app/data/ssh/id_ed25519",
  sshUser: process.env.WEBUI_SSH_USER || "ubuntu",
  baseUrl: (process.env.WEBUI_BASE_URL || "").replace(/\/+$/, ""),   // e.g. https://vmpilot.lan — used for clickable links in alert emails
  sessionHours: intEnv("WEBUI_SESSION_HOURS", 8),
  nodeEnv: process.env.NODE_ENV || "production",
  isProd: (process.env.NODE_ENV || "production") === "production"
};
