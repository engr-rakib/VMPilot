// components.js — shared UI pieces.
import { html } from "./core.js";

export function Pill({ cls = "", children }) {
  return html`<span className=${"pill " + cls}>${children}</span>`;
}

export function Spinner({ inline = false }) {
  return html`<span className=${inline ? "spinner inline" : "spinner"} />`;
}

export function PowerBadge({ power }) {
  if (power === "poweredOn") return html`<span className="pill ok">● on</span>`;
  if (power === "poweredOff") return html`<span className="pill off">● off</span>`;
  return html`<span className="pill pending">pending</span>`;
}

export function Btn({ cls = "ghost", onClick, disabled, children, title }) {
  return html`<button className=${cls} onClick=${onClick} disabled=${disabled} title=${title}>${children}</button>`;
}