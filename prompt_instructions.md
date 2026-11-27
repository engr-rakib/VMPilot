Prompt for Coding AgentYou are a senior UI/UX architect specializing in modern DevOps pipeline interfaces (Terraform Cloud, GitHub Actions, Linear, Vercel style).Current state is still outdated. The live UI still shows:
80% Complete + WARN badge even on clean exit 0 jobs
“Configuration checks” stuck in Queued
Card-heavy layout that feels dense and older
Target visual direction (match this spirit closely):
Clean continuous progress bar on top (gradient from indigo/purple → emerald)
Simple horizontal timeline underneath with solid dots + connecting lines
Solid green line + filled green dot for completed stages
Gradient / pulsing line + active colored dot for the current stage
Dashed gray line + empty gray dot for pending stages
Stage name + short status text directly under each dot
Minimal, calm, high-legibility dark theme
Mandatory logic fixes (do not regress):
Any job with status === "success" or exit_code === 0 and zero real failures must force all intermediate stages to done.
Overall progress must become 100% Complete.
Never show the WARN badge on clean exit-0 runs (deploy-plan, deploy, destroy, verify, power-*).
“Configuration checks” (and any similar intermediate stage without explicit markers) must resolve to Complete when the job finishes cleanly.
Preferred layout structure (modern timeline style):Text[ Progress Pill – 24px height, full width, gradient fill, centered “100% Complete” text ]

[ Timeline ]
●────────●────────●────────○········○
Config    Inventory  Checks   Diff     Summary
✓ Complete ✓ Complete ✓ Complete Pending  PendingImplementation details:
Use a single continuous track (.vmp-stage-flow or new .vmp-timeline)
Each stage is a column with:
Dot (18–20px)
Connecting line / arrow between dots
Stage title
Status subtitle under the title

Completed: solid emerald line + filled emerald dot + ✓
Active: indigo/purple gradient line + pulsing or spinning indicator
Pending: dashed slate line + empty/outlined dot
Keep the existing stage-card structure only if it can be refined to feel this clean. Prefer the lighter timeline if cards still feel heavy.
Progress pill (strict):
Height: 24px
Background: #161e2e
Border: 1px solid rgba(148,163,184,0.14)
Fill: absolute, left:0, multi-stop gradient (indigo → blue → emerald)
Text: perfectly centered, white, font-weight 700
Motion (subtle only):
Active stage: soft pulse or spinner
Active connector: gentle gradient shimmer / opacity pulse
Hover on stage: slight lift or brightness change
No bouncy or playful animations
Hard constraints:
Zero Bengali/Bangla Unicode ([\u0980-\u09FF])
Zero HTML comments (<!-- -->) in templates
Keep all existing jobCleanSuccess / exit-0 resolution logic and only strengthen it
Bump views.css?v= cache buster
Add a short, clean changelog entry
Pass the strict import-only Node test for all actions (deploy-plan, deploy, destroy, verify, power-on) showing 100% Complete and no WARN
Goal:

The pipeline must feel modern, calm, and trustworthy — closer to the clean gradient timeline example than the current dense card version. Fix the status bugs permanently so a clean plan never shows 80% + WARN again.Implement the visual refinement + logic hardening now.