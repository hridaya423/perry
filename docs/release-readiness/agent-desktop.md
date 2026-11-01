# agent-desktop acquisition

Perry pins the Apple Silicon build of [agent-desktop](https://github.com/vercel-labs/agent-desktop) (Apache-2.0) to the release below. The lock file `scripts/agent-desktop.lock` is the acquisition contract. The fetch script never queries a latest endpoint or follows a moving tag.

| Field | Pinned value |
| --- | --- |
| Version | `1.0.2` |
| Target | `aarch64-apple-darwin` |
| Release tag | [`v1.0.2`](https://github.com/vercel-labs/agent-desktop/releases/tag/v1.0.2) |
| Asset | `agent-desktop-v1.0.2-aarch64-apple-darwin.tar.gz` |
| Archive SHA256 | `7bee385196d7b478de80cf05ca4304aaa38f0eba593b3406ad3c247c1773be19` |
| `agent-desktop` SHA256 | `bf0a3c9256512f2f57288d37ccd17d7f03665fccc53c2f74011a49b98e61ba59` |
| `agent-desktop-macos-helper` SHA256 | `522829116cb006b5770c6a82b361f466a4775f794d6af4083e75231a2d6bb551` |
| Source revision | [`a47ed664e0db00d1d4df364eb3fe8a5599882f3c`](https://github.com/vercel-labs/agent-desktop/commit/a47ed664e0db00d1d4df364eb3fe8a5599882f3c) |

Upstream binaries are ad-hoc signed with no team, so the hashes are the integrity check. Release signing re-signs both binaries with Perry's Developer ID and hardened runtime, inside out, with identifiers `agent-desktop` and `agent-desktop-macos-helper`. At runtime a Developer ID build of Perry accepts the bundled driver only when it carries the same team and the identifier `agent-desktop`. Unsigned and ad-hoc development builds accept it from inside the app bundle.

Run the checks from the repository root:

```sh
scripts/fetch-agent-desktop.sh --check-lock
scripts/fetch-agent-desktop.sh --check
scripts/test-agent-desktop.sh
```

`--check-lock` validates the contract without the network. `--check` verifies the installed `App/Resources/AgentDesktop/bin/` payload and its `.version` marker, and fails closed without calling `curl`. `--fetch` downloads the exact asset, verifies the archive and both member hashes, checks both are arm64 only, and then installs them.

Perry runs `agent-desktop` as a child process, one command per call, with `--session <worker id>` and `AGENT_DESKTOP_HOME` under Perry's support directory. The first call in a session starts a command host that inherits Perry's Accessibility and Screen Recording grants and exits after 15 idle minutes. Retiring a worker kills its in-flight commands and that session's host. Cancelling an action (Stop) also ends that session's host, so a command the host already accepted cannot finish later; cancelling a read does not. User text travels in the command line after `--` (agent-desktop has no stdin input); macOS shows another process's arguments only to the same user, and Perry refuses text over 200,000 bytes with a plain message instead of failing to launch.

## cua-driver fallback

Perry also ships cua-driver (see [cua-driver.md](cua-driver.md)) as a background fallback. agent-desktop handles reads, typing and control clicks. cua-driver handles:

- clicks at a point and drags, so the user's cursor never moves;
- a control click that agent-desktop refuses with `disposition.delivery: not_delivered`, so the first click never happened;
- a plain `click` that agent-desktop reports as `delivered_unverified` with no sheet, menu or alert open. Perry then clicks the control's centre once through cua. It does this only for a labelled button, link, tab, radio button, menu item, row or cell whose label holds no consequential word (send, delete, pay, add, new, cancel, and similar). It never repeats a toggle, a pop-up, a right-click or a double-click.

Any failure that may have landed (`delivered_unverified`, a timeout, or a dead process) is reported and never retried, through either driver. User text goes after `--`, so text that starts with `-` cannot become a flag.

## Stage Manager

agent-desktop lists a window in the Stage Manager strip at its thumbnail size (about 143 × 136 pt), with a `com.apple.WindowManager` "Gesture Blocking Overlay" window at the same bounds. Its accessibility tree still reports the real frame. Perry treats a window with a matching overlay as staged, and never targets WindowManager's own windows. A foreground worker brings a staged window to the front (`focus-window`) before it looks. A background worker can read a staged window's tree and use semantic actions. It refuses a screenshot (it would be the thumbnail) and every physical click (it would land on the thumbnail and bring the window forward), and says so.

Without a usable cua-driver, pointer input falls back to agent-desktop's foreground mode on foreground workers and fails with a clear message on background ones.

