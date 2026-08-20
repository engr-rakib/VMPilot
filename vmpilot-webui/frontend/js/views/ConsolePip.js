// views/ConsolePip.js — floating picture-in-picture SSH console popup.
// Thin wrapper over the unified PipWindow chrome (drag / resize / minimize /
// close / move-to-workspace) hosting ConsoleView. Opened from the Monitor 🖥
// button WITHOUT navigating away. Minimize is externally driven by Shell's
// bottom ribbon (minimized + onMinimize) so multiple consoles stack side by
// side; the hidden body keeps the SSH session alive.
import { html } from "/js/core.js";
import ConsoleView from "/js/views/ConsoleView.js";
import PipWindow from "/js/views/PipWindow.js";

const PIP_W = 560, PIP_H = 500, MIN_W = 320, MIN_H = 260;

export default function ConsolePip({ vm, name, vc, user, diskGb, onClose, onMoveWorkspace, minimized, onMinimize }) {
  return html`
    <${PipWindow} icon="🖥"
      title=${`${name || "VM"} · ${user || "ubuntu"}@${vm}`}
      w=${PIP_W} h=${PIP_H} minW=${MIN_W} minH=${MIN_H}
      minimized=${minimized} onMinimize=${onMinimize}
      onClose=${onClose} onMoveWorkspace=${onMoveWorkspace}>
      <${ConsoleView} vm=${vm} name=${name} vc=${vc} user=${user} diskGb=${diskGb} hidePin />
    </${PipWindow}>`;
}