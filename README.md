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
3. Merges hooks into `~/.claude/settings.json` and backs up the original to `settings.json.vibewake-backup`. It also adds a short block, between `<!-- vibewake:start -->` and `<!-- vibewake:end -->`, to `~/.claude/CLAUDE.md` (see [How prompts are delivered](#how-prompts-are-delivered)).
4. Installs the pi extension to `~/.pi/agent/extensions/vibewake/`.
5. Adds a LaunchAgent that starts VibeWake at login and restarts it if it crashes.

Restart running agent sessions afterwards, or run `/reload` in pi.

To remove everything: `./scripts/uninstall.sh`.

## How activity is detected

The app counts an agent as busy when any of the following is true:

| Source | Busy while |
|---|---|
| Claude Code hooks | A turn is running (`UserPromptSubmit` until `Stop` or `StopFailure`), or a subagent is running (`SubagentStart` until `SubagentStop`), including background subagents. Every tool call counts as a heartbeat. |
| pi extension | From `agent_start` until `agent_settled`. Retries, compaction and queued follow-ups are included. pi-subagents register themselves. |
| Background tasks | An agent process (`claude`, `codex`, or a pi with a registered session) has a shell child that has run for 5 seconds or more. This covers `run_in_background` commands and long foreground commands. |
| Process fallback | `codex`, `opencode`, `gemini` or `aider` uses more than 3% CPU, or has a running shell child. |

Hooks write small JSON markers to `~/.vibewake/active/`. The rules for clearing them:

- A marker whose process has died is deleted.
- A turn with no heartbeat for 20 minutes and no running shell is treated as stale. This happens, for example, when you interrupt with Esc.

Check the current state from a terminal with `VibeWake status`. For history, see [Logs](#logs).

## Agents window and autopilot

Choose **Show Agents…** in the menu (⌘A while the menu is open), or run `VibeWake agents`, to open a floating window that lists every open Claude Code chat with its title, project and state:

| Dot | State |
|---|---|
| Green | Working on a turn |
| Grey | Idle, waiting for a prompt |
| Purple | Stopped by a usage limit; shows when it resets |
| Orange | Working, but no sign of life for 20 minutes or more |
| Yellow | Waiting for you to answer a permission prompt or question |

The autopilot acts on these chats by sending prompts into them. It can be switched on or off per feature at the bottom of the window:

- **Continue after usage limit.** When a turn fails with a usage limit, VibeWake sends `continue` one minute after the limit resets. If the limit is still active, the new failure schedules the next attempt.
- **Nudge stalled chats.** When a turn shows no tool activity for 20 minutes, VibeWake sends `what is the status?`. It nudges again every 20 minutes, at most three times, until the chat shows activity again. A chat interrupted with Esc is not considered stalled, and neither is one waiting for you to answer a permission prompt or question. That chat isn't nudged and doesn't keep the Mac awake, since nothing happens until you answer.
- **Run queues.** Each chat has a prompt queue. Every time the chat finishes a turn, the next prompt is sent:
  - **Same chat** sends it into the same conversation.
  - **New chat** opens a new Claude Code tab in VS Code for the same project and sends the prompt there once the tab has started. If the new tab doesn't register within 60 seconds, VibeWake opens it with the prompt pre-filled instead, and you press Enter.

While the autopilot has something pending, VibeWake keeps the Mac awake as if an agent were working, including with the lid closed. This covers a `continue` waiting for a usage limit to reset (which can mean hours with the lid closed), a stalled chat that hasn't had all its nudges, and a queued prompt waiting to run. Otherwise the Mac would sleep after the last turn ends and the autopilot couldn't act. The low-battery rule still applies, and **Pause** turns this off too.

A chat counts as stalled only if no shell command is running in it, so a long build or test run isn't nudged. If a queued prompt doesn't start a turn, it goes back to the front of the queue. Queues of chats that have closed (including after `/clear`) are dropped, and each dropped prompt is logged.

The window also has **Ask for status**, **Continue** and **Send now** buttons for doing this by hand. If a prompt can't be delivered, or doesn't start a turn within two minutes, the autopilot pauses for that chat for 10 minutes. **Resume autopilot** restarts it right away.

From a terminal:

```bash
VibeWake sessions                                 # list chats with id, title and state
VibeWake send <id-prefix|title> <text>            # send a prompt now
VibeWake queue <id-prefix|title> [--new-chat] <text>   # add to the queue
```

The prompts, the stall threshold, the maximum number of nudges and the editor URL scheme (`vscode` by default, `cursor` for Cursor) are stored in `~/.vibewake/state/settings.json`. Queues are stored in `~/.vibewake/queue/`.

### How prompts are delivered

Claude Code (v2.1.224 or later) gives each session an inbox socket for [cross-session messaging](https://code.claude.com/docs/en/cross-session-messaging). VibeWake's hook records each session's socket path and token in its marker file, which only your user can read, and the autopilot writes prompts to that socket. Some consequences:

- Claude sees these prompts as messages from another session, not as typed by you. They can't approve permission prompts.
- The chat UI hides inbox messages. VibeWake starts each one with `[vibewake]`, and the block in `~/.claude/CLAUDE.md` asks Claude to repeat a tagged prompt in bold at the start of its reply, so you can see what it is working on.
- During a turn, Claude reads a message between tool calls, so a nudge can't interrupt a tool that is still running.
- If you set `crossSessionInbound` to `refuse` or `hold`, the autopilot can't deliver.
- Chats started before you install the updated hooks can't receive prompts until they fire a hook again. Sending any prompt is enough.
- pi chats are listed but can't receive prompts.

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
| `[autopilot]` | Prompts sent by the autopilot or `VibeWake send`, and failed deliveries |
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
