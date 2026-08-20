// views/ExpandConsole.js — "Disk Resize" execute-action card.
// A floating picture-in-picture window hosting the live JobThread
// (stepper + progress + console output) — SAME unified PipWindow chrome as the
// VM console / global Terminal. Opened from the Monitor disk card "Grow"
// action WITHOUT navigating away; draggable, resizable, minimizable (self
// minimizes to a bottom-right pill — job keeps running server-side).
import { html } from "/js/core.js";
import JobThread from "/js/views/JobThread.js";
import PipWindow from "/js/views/PipWindow.js";
import { actionLabel } from "/js/api.js";

const STATUS_COLOR = {
  queued: "#eab308", running: "#22d3ee", success: "#4ade80", failed: "#f87171"
};
const W = 680, H = 520, MIN_W = 420, MIN_H = 320;

export default function ExpandPip({ job, onClose }) {
  const st = job.status;
  const running = st === "running" || st === "queued";
  const mount = (job.params && job.params.mount) || "";

  return html`
    <${PipWindow} icon="💾"
      title=${`${actionLabel(job.action)} · ${mount}`}
      status=${html`<span className="job-status" style=${{ color: STATUS_COLOR[st] }}>${running ? "● live" : st}</span>
        ${job.exit_code != null ? html`<span className="muted">exit ${job.exit_code}</span>` : ""}`}
      w=${W} h=${H} minW=${MIN_W} minH=${MIN_H}
      onClose=${onClose}
      pill=${html`<span>💾 ${actionLabel(job.action)} · ${mount} · <span style=${{ color: STATUS_COLOR[st] }}>${running ? "● " + st : st}</span></span>`}>
      <${JobThread} job=${job} />
    </${PipWindow}>`;
}