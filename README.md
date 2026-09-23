# VibeWake

A menu bar app that keeps your Mac awake, **even with the lid closed**, while AI coding agents are working. It restores normal sleep once they're done.

| Icon | Meaning |
|---|---|
| Robot, white (black on a light menu bar) | Idle. Normal sleep rules apply. |
| Robot, soft green + count | Agents are working. The Mac won't sleep, even with the lid closed. |
| Robot, faded green | Winding down. The last activity ended less than 60 seconds ago. |
| Robot, faded grey | Paused from the menu. Normal sleep rules apply. |

When the last agent finishes with the lid closed, VibeWake puts the Mac to sleep right away, as closing the lid normally would. It doesn't do this in clamshell mode, when an external display is connected.

## Install

```bash
./scripts/install.sh
```

The script does the following:

1. Builds `~/Applications/VibeWake.app`.
2. Adds `/etc/sudoers.d/vibewake`, which lets your user run **only** `pmset -a disablesleep 0|1` without a password. This asks for your password once. It is the only way to stop lid-close sleep.
3. Merges hooks into `~/.claude/settings.json` and backs up the original to `settings.json.vibewake-backup`.
4. Installs the pi extension to `~/.pi/agent/extensions/vibewake/`.
5. Adds a LaunchAgent that starts VibeWake at login and restarts it if it crashes.

Restart running agent sessions afterwards, or run `/reload` in pi.

To remove everything: `./scripts/uninstall.sh`.

## How activity is detected

The app counts an agent as busy when any of the following is true:

| Source | Busy while |
|---|---|
| Claude Code hooks | A turn is running (`UserPromptSubmit` until `Stop`), or a subagent is running (`SubagentStart` until `SubagentStop`), including background subagents. Every tool call counts as a heartbeat. |
| pi extension | From `agent_start` until `agent_settled`. Retries, compaction and queued follow-ups are included. pi-subagents register themselves. |
| Background tasks | An agent process (`claude`, `codex`, or a pi with a registered session) has a shell child that has run for 5 seconds or more. This covers `run_in_background` commands and long foreground commands. |
| Process fallback | `codex`, `opencode`, `gemini` or `aider` uses more than 3% CPU, or has a running shell child. |

Hooks write small JSON markers to `~/.vibewake/active/`. The rules for clearing them:

- A marker whose process has died is deleted.
- A turn with no heartbeat for 20 minutes and no running shell is treated as stale. This happens, for example, when you interrupt with Esc.

Check the current state from a terminal with `VibeWake status`. For history, see [Logs](#logs).

## Logs

Everything is logged to `~/.vibewake/vibewake.log`. When the file reaches 2 MB it rotates to `vibewake.log.1`.

Choose **Show Logs…** in the menu (⌘L while the menu is open), or run `VibeWake logs` in a terminal, to open the log window. The window:
- floats above other windows and updates live;
- follows new entries when you're scrolled to the bottom;
- colors entries by category;
- can filter by text or category;
- has Copy, Show in Finder and Clear buttons;
- closes with Esc.

| Category | What gets logged |
|---|---|
| `[claude]` / `[pi]` | Session opened or closed, prompt submitted, turn finished (with duration), subagent started or finished |
| `[session]` | What VibeWake counts as active: STARTED / FINISHED (with duration), subagent and shell-task counts, crashed agents |
| `[state]` | Switches between ACTIVE, IDLE and PAUSED |
| `[sleep]` | Power assertion on/off, `disablesleep` on/off (or a failure), forced sleep after work ends with the lid closed, low-battery override |
| `[system]` | Mac going to sleep or waking up, display sleep or wake, lid closed or opened |
| `[app]` | Start, quit, pause, and installs |

## Safety

- VibeWake only undoes a `disablesleep` that it set itself. It tracks this in `~/.vibewake/state/`.
- `disablesleep` is reset on Quit, on SIGTERM, and on the next launch after a crash. The LaunchAgent relaunches the app after a crash.
- On battery below 10% with the lid closed, VibeWake allows sleep anyway.
- The menu has **Pause (allow sleep)** to turn it off for a while.
