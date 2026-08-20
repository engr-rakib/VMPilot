"use strict";

const jwt = require("jsonwebtoken");
const bcrypt = require("bcryptjs");
const config = require("./config");

const COOKIE_NAME = "vmpilot_sid";
const ALGO = "HS256";

// Default roles (seeded). Custom roles are stored in the roles table.
const VALID_ROLES = ["viewer", "operator", "admin"];

let userStore = null;
let roleStore = null;

function useUserStore(store) {
  userStore = store;
}

function useRoleStore(store) {
  roleStore = store;
}

function signToken(sub, role) {
  return jwt.sign({ sub, role }, config.secret, {
    algorithm: ALGO,
    expiresIn: `${config.sessionHours}h`,
    issuer: "vmpilot-webui",
    audience: "vmpilot-webui"
  });
}

// Constant-time-ish login: always run a bcrypt compare so username
// enumeration via timing is not possible.
async function login(username, password) {
  const pw = String(password || "");
  const u = userStore ? userStore.getByUsername(String(username)) : null;
  if (u) {
    if (u.disabled) return null;
    const ok = await bcrypt.compare(pw, u.pass_hash);
    if (!ok) return null;
    if (u.id) userStore.update(u.id, { last_login: Date.now() });
    return signToken(u.username, u.role);
  }
  // Bootstrap fallback: single admin from config (seeded into users on first
  // boot — kept here so an old cookie/config still authenticates).
  const h = config.passHash;
  if (!h) return null;
  if (String(username) !== config.user) {
    await bcrypt.compare(pw, h);
    return null;
  }
  const ok = await bcrypt.compare(pw, h);
  return ok ? signToken(config.user, "admin") : null;
}

function cookieOpts(req) {
  return {
    httpOnly: true,
    // Secure cookies are only sent over HTTPS. NODE_ENV alone is not enough:
    // in "production" the Node server is also reachable directly over plain
    // HTTP (no nginx), where a Secure cookie would never be sent back and the
    // whole session appears "logged out" (401 on every API call). Derive it
    // from the actual connection instead (nginx sets X-Forwarded-Proto and
    // Express has `trust proxy` enabled, so req.secure is reliable there).
    secure: config.isProd ? Boolean(req && req.secure) : false,
    sameSite: "strict",
    maxAge: config.sessionHours * 3600 * 1000,
    path: "/"
  };
}

function setSessionCookie(req, res, token) {
  res.cookie(COOKIE_NAME, token, cookieOpts(req));
}

function clearSessionCookie(req, res) {
  res.clearCookie(COOKIE_NAME, cookieOpts(req));
}

function tokenFromCookieHeader(header) {
  if (!header) return null;
  for (const part of header.split(";")) {
    const i = part.indexOf("=");
    if (i < 0) continue;
    if (part.slice(0, i).trim() === COOKIE_NAME) {
      return part.slice(i + 1).trim();
    }
  }
  return null;
}

function verifyToken(token) {
  try {
    return jwt.verify(token, config.secret, {
      algorithms: [ALGO],
      issuer: "vmpilot-webui",
      audience: "vmpilot-webui"
    });
  } catch {
    return null;
  }
}

function payloadFromRequest(req) {
  const token = tokenFromCookieHeader(req.headers && req.headers.cookie);
  return token ? verifyToken(token) : null;
}

// Permission catalogue — every action in the console maps to one of these.
const PERMISSIONS = [
  "view",                 // read everything (inventory, monitor, events, tasks, settings)
  "deploy",               // deploy / plan / sync / destroy / backup / restore / power
  "config.write",         // create / edit / delete VM configs, secure files, vCenters
  "terminal",             // terminal access
  "users.manage",         // manage users + roles
  "settings.manage"       // alerting / SMTP settings
];

// Built-in roles and their permission sets. Custom roles store their own
// permission array in the roles table (makeRoleStore).
const BUILTIN_ROLES = {
  viewer: ["view"],
  operator: ["view", "deploy", "config.write", "terminal"],
  admin: ["view", "deploy", "config.write", "terminal", "users.manage", "settings.manage"]
};

function permissionsOf(roleName) {
  const builtin = BUILTIN_ROLES[roleName];
  if (builtin) return builtin;
  if (roleStore) {
    const perms = roleStore.permissionsOf(roleName);
    if (perms && perms.length) return perms;
  }
  return [];
}

function hasPerm(roleName, perm) {
  const perms = permissionsOf(roleName);
  return perms.includes("*") || perms.includes(perm);
}

function effectivePermissions(roleName) {
  return permissionsOf(roleName);
}

function requireAuth(req, res, next) {
  const p = payloadFromRequest(req);
  if (!p) return res.status(401).json({ error: "unauthorized" });
  req.auth = p;
  next();
}

// requirePerm("deploy") — grants access when the token's role holds the
// permission. Used after requireAuth.
function requirePerm(perm) {
  return (req, res, next) => {
    if (!req.auth) return res.status(401).json({ error: "unauthorized" });
    if (!hasPerm(req.auth.role, perm)) {
      return res.status(403).json({ error: "forbidden: requires permission " + perm });
    }
    next();
  };
}

// Backward-compat alias: requireRole("operator") ≈ requirePerm(deploy).
function requireRole(role) {
  const minPerm = role === "admin" ? "users.manage" : role === "operator" ? "deploy" : "view";
  return requirePerm(minPerm);
}

function can(role, perm) {
  return hasPerm(role, perm);
}

module.exports = {
  COOKIE_NAME,
  useUserStore,
  useRoleStore,
  VALID_ROLES,
  PERMISSIONS,
  BUILTIN_ROLES,
  login,
  setSessionCookie,
  clearSessionCookie,
  tokenFromCookieHeader,
  verifyToken,
  payloadFromRequest,
  requireAuth,
  requirePerm,
  requireRole,
  can,
  permissionsOf,
  effectivePermissions
};