// js/xterm-clip.js — robust copy/paste for xterm.js terminals (ConsoleView + Terminal).
//   - Ctrl+C with a selection  → copy + clear selection (no SIGINT)
//   - Ctrl+C without selection → normal SIGINT (unchanged shell behavior)
//   - Ctrl+V / Ctrl+Shift+V    → paste clipboard into the pty
//   - multi-line paste wrapped in bracketed-paste markers when the shell enabled them
//   - Clipboard API missing (insecure context) → execCommand fallback copy
export function attachClipboard(term) {
  const fallbackCopy = (text) => {
    try {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.focus();
      ta.select();
      document.execCommand("copy");
      document.body.removeChild(ta);
    } catch { /* ignore */ }
  };
  const copyText = (text) => {
    if (!text) return;
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).catch(() => fallbackCopy(text));
        return;
      }
    } catch { /* ignore */ }
    fallbackCopy(text);
  };
  const pasteText = (text) => {
    if (!text) return;
    // Respect bracketed paste: a multi-line paste must not execute as one buffer.
    const bp = term.modes && term.modes.bracketedPasteMode;
    let data = text;
    if (bp) data = "\x1b[200~" + data.replace(/\r?\n/g, "\r") + "\x1b[201~";
    try { term.paste(data); } catch { term.write(data); }
  };
  const readPaste = () => {
    if (navigator.clipboard && navigator.clipboard.readText) {
      navigator.clipboard.readText().then(pasteText).catch(() => { /* permission denied */ });
    }
  };
  term.attachCustomKeyEventHandler((e) => {
    const mod = e.ctrlKey || e.metaKey;
    if (mod && String(e.key || "").toLowerCase() === "c") {
      if (term.hasSelection()) {
        e.preventDefault();
        copyText(term.getSelection());
        try { term.clearSelection(); } catch { /* ignore */ }
        return false; // handled — do NOT send SIGINT
      }
      return true; // no selection → let the shell receive Ctrl+C
    }
    if (mod && String(e.key || "").toLowerCase() === "v") {
      e.preventDefault();
      readPaste();
      return false;
    }
    return true;
  });
  return { copy: () => copyText(term.getSelection()), paste: readPaste };
}