"use strict";

// Generate a bcrypt password hash for WEBUI_PASS_HASH.
// Usage:
//   node scripts/gen-pass.js <password>    (one-shot, e.g. in a script)
//   node scripts/gen-pass.js               (prompts interactively)
const bcrypt = require("bcryptjs");
const readline = require("readline");

function ask(promptText) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => rl.question(promptText, (a) => { rl.close(); resolve(a); }));
}

async function main() {
  let password = process.argv[2];
  if (!password) {
    password = await ask("Password: ");
  }
  if (!password) {
    console.error("no password given");
    process.exit(1);
  }
  const hash = await bcrypt.hash(password, 12);
  console.log(hash);
}

main().catch((e) => { console.error(e); process.exit(1); });
