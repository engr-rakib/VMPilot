// views/JobThread.js — one job's live output rendered inside a conversation
// bubble (used by Shell.js thread). Same socket.io code path as the Jobs tab.
// Shows a workflow lifecycle stepper + animated progress + live console output.
import { html, useState, useEffect, useRef } from "/js/core.js";
import { getJobOutput, actionLabel } from "/js/api.js";

// Terraform/CLI emit ANSI color codes even with TERM=dumb; strip them so the
// console stays readable. Also collapse consecutive blank lines.
const ANSI_RE = /[\u001b\u009b][[()#;?]*(?:[0-9]{1,4}(?:;[0-9]{0,4})*)?[0-9A-ORZcf-nqry=><]/g;
const clean = (s) => String(s || "").replace(ANSI_RE, "").replace(/\n{3,}/g, "\n\n");

const STATUS_COLOR = {
  queued: "#eab308", running: "#22d3ee", success: "#4ade80", failed: "#f87171"
};

const timeAgo = (at) => {
  if (!at) return "—";
  const s = Math.max(0, Math.floor((Date.now() - Number(at)) / 1000));
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
};

const fullDt = (at) => {
  if (!at) return "";
  try { return new Date(Number(at)).toLocaleString(); } catch { return ""; }
};

// Deploy/sync lifecycle phases, detected from script output. Falls back to a
// coarse stepper for other actions (backup/restore/destroy).
const PHASES = [
  { id: "queued", label: "Queued", match: null },
  { id: "config", label: "Config", match: /VM config|Combined config|State file|Deploy-time policy/ },
  { id: "plan", label: "Plan", match: /Planning:|terraform plan|^Plan:/ },
  { id: "apply", label: "Apply", match: /Applying:|terraform apply|Creating\.\.\.|Still creating|module\.vm\[/ },
  { id: "done", label: "Done", match: /Done:|deployed|cloud-init|IP:/ }
];

function phaseFromOutput(out) {
  for (let i = PHASES.length - 1; i >= 0; i--) {
    if (PHASES[i].match && PHASES[i].match.test(out)) return i;
  }
  return 0;
}

export default function JobThread({ job: jobInit }) {
  const [job, setJob] = useState(jobInit);
  const [output, setOutput] = useState("");
  const [live, setLive] = useState(false);
  const [err, setErr] = useState("");
  const [tick, setTick] = useState(0);
  const outRef = useRef(null);
  const socketRef = useRef(null);

  useEffect(() => {
    let active = true;
    // seed from the persisted log first (same polling loop as Jobs.js)
    (async () => {
      setErr("");
      try {
        let offset = 0;
        while (active) {
          const { output: chunk, offset: next } = await getJobOutput(job.id, offset);
          setOutput((o) => (o + clean(chunk)).slice(-200000));
          if (next <= offset || chunk.length === 0 || offset > 1500000) break;
          offset = next;
        }
      } catch (e) {
        if (active) setErr((e && e.message) || "failed to load log");
      }
    })();

    // stream live output for queued/running jobs
    if (job.status === "queued" || job.status === "running") {
      const socket = window.io("/jobs");
      socketRef.current = socket;
      socket.on("job:output", ({ jobId, line }) => {
        if (jobId === job.id) setOutput((o) => (o + clean(line)).slice(-200000));
      });
      socket.on("job:status", ({ jobId, status, exit_code }) => {
        if (jobId === job.id) {
          setJob((cur) => ({ ...cur, status, exit_code }));
          if (status !== "running" && status !== "queued") setLive(false);
        }
      });
      socket.on("connect", () => setLive(true));
      socket.on("disconnect", () => setLive(false));
    }

    return () => { active = false; socketRef.current?.disconnect(); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [job.id, tick]);

  useEffect(() => {
    outRef.current?.scrollTo(0, outRef.current.scrollHeight);
  }, [output]);

  const st = job.status;
  const phase = phaseFromOutput(output);
  const running = st === "running" || st === "queued";
  const done = st === "success";
  const failed = st === "failed";
  const pct = done ? 100 : failed ? 100 : running ? Math.round(((phase + 0.5) / PHASES.length) * 100) : 0;
  const barColor = failed ? "var(--danger)" : done ? "var(--ok)" : "var(--accent)";

  return html`
    <div className="thread-job">
      <div className="thread-job-head">
        <span className="thread-job-action">${actionLabel(job.action)}</span>
        <span className="job-status" style=${{ color: STATUS_COLOR[st] }}>
          ${live && running ? "● live" : st}
        </span>
        ${job.exit_code != null && html`<span className="muted">exit ${job.exit_code}</span>`}
        ${job.started_at ? html`<span className="muted" title=${fullDt(job.started_at)}>started ${timeAgo(job.started_at)}</span>` : ""}
        ${job.finished_at ? html`<span className="muted" title=${fullDt(job.finished_at)}>· finished ${timeAgo(job.finished_at)}</span>` : ""}
        ${running && html`<span className="muted">${pct}%</span>`}
      </div>

      <div className="job-stepper">
        ${PHASES.map((p, i) => html`
          <div key=${p.id} className=${(i < phase || (done && i < PHASES.length)) ? "js-step done" : i === phase && running ? "js-step active" : failed && i === phase ? "js-step fail" : "js-step"}>
            <span className="js-dot">${i < phase || done ? "✓" : i === phase && running ? "●" : "○"}</span>
            <span className="js-label">${p.label}</span>
          </div>`)}
      </div>

      <div className="job-progress">
        <div className="job-progress-track"><div className=${running ? "job-progress-fill animate" : "job-progress-fill"} style=${{ width: pct + "%", background: barColor }} /></div>
        <span className="job-progress-pct">${failed ? "failed" : done ? "done" : pct + "%"}</span>
      </div>

      <pre className="job-output thread-job-output" ref=${outRef}>${output}</pre>
      ${err && html`<p className="muted thread-job-err">${err} <button className="mini" onClick=${() => setTick((t) => t + 1)}>retry</button></p>`}
      ${!err && !output && !running && html`<p className="muted thread-job-err">No console output recorded for this job.</p>`}
    </div>`;
}