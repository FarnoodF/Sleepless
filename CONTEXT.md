# Context

## Glossary

- **Keep-awake state**: The user-controlled state where Sleepless keeps the Mac awake when it would otherwise sleep.
- **Agent auto-off**: A safety cutoff that may end the keep-awake state when no monitored agents are active. It does not start or re-enable the keep-awake state.
- **Active agent**: A monitored coding-agent session that Sleepless can detect through local CLI, process, or session signals without reading another app's UI. A live session counts as active even when it is waiting for input or approval. Detection may use at most one optional, non-screen macOS permission when it provides reliable non-UI signals.
- **Locally observable agent**: Agent work with a local process, worker, session signal, or integration heartbeat. Cloud-only agent work without a local signal is outside Sleepless' monitoring contract.
- **Monitored agent tool**: An installed coding-agent tool for which Sleepless has a reliable local detector. Tools without reliable detectors are not shown in agent status and do not affect agent auto-off.
- **Installed agent tool**: A coding-agent tool discovered through bounded, tool-specific signals such as a validated CLI executable, a known app bundle identifier, or an official local integration. Sleepless does not use exhaustive filesystem searches to discover tools.
- **Agent integration**: An app-wide, opt-in integration such as a hook or heartbeat that helps Sleepless detect active agents without UI scraping. Project-by-project integrations are too high-friction to be required, and app-wide integrations are required only when default local detection is not reliable enough.
- **Healthy agent detection**: The state where Sleepless has the required local signals and any required permission to evaluate at least one monitored agent tool. Agent auto-off starts inactive, asks for required permission only when the user enables it, and stays enabled while at least one monitored tool is available.
- **Agent status**: The user-visible state of a monitored agent tool, shown as Active, Idle, or Setup needed.
- **Agent setup**: A per-tool action in the controls popover that sets up required app-wide integrations or prompts for required permission. Detailed explanation lives in documentation rather than a setup wizard.
- **No agent tools available**: The state where Sleepless finds no monitored agent tools. The controls popover explains that no supported agent tools were found, and agent auto-off is unavailable.
- **Controls popover**: The single menu-bar popover where Sleepless exposes keep-awake controls, safety cutoffs, and monitored agent status.
- **Agent coffee logo**: The robot-with-coffee brand mark used for app and marketing identity. The menu bar uses a simplified monochrome template glyph derived from the same idea.
- **Native lightweight app**: Sleepless remains a small native macOS menu-bar app, but implementation may be split across focused Swift files when features are too broad for a single source file.
- **No internet connection**: A sustained inability to reach the public internet across consecutive checks, determined from macOS network path status plus a lightweight HTTPS reachability probe.
- **Realtime agent status**: A visible status that updates every three seconds while the user is looking at the controls.
- **Auto-off grace period**: A two-minute delay before an agent or internet safety cutoff acts, used to avoid turning off during transient network drops, tool restarts, or session handoffs.
- **Safety cutoff**: Any enabled condition that may end the keep-awake state. Safety cutoffs combine independently; any one of them may turn Sleepless off. New cutoffs default off until the user enables them.
