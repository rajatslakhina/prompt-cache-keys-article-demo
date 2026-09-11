# ContextCacheKit

**Your prompt cache is a production SLO, and your tool list, CLAUDE.md and skills are its cache keys.**
This package models the API's prefix cache the way the docs describe it, replays a realistic
40-turn iOS-monorepo agent session through it, and prices every miss at the published Claude
Fable 5.1 rates. It is the demo for the Medium article linked below.

Article: (added after publish)

## What it shows

Seven ordinary things happen during one afternoon of agentic coding: a teammate re-announces its
tools, a skill is loaded, an MCP server reconnects, lunch, a CLAUDE.md merge, another skill, a
tool schema re-render. The cache hit ratio still reads **85.6%**. The seven misses cost
**$3.41**; the other 33 turns cost **$1.24** combined.

| Session | Misses | Hit ratio | Tokens re-cached | Input cost | Overspend vs ideal |
| --- | ---: | ---: | ---: | ---: | ---: |
| Baseline | 7 | 85.6% | 255,071 | $4.65 | $3.12 |
| Stabilized (5 min TTL) | 1 | 94.2% | 56,613 | $2.22 | $0.69 |
| Stabilized (1 h TTL) | 0 | 96.6% | 0 | $2.11 | $0.00 |

The same afternoon with no cache at all would cost $23.10, which is why the hit ratio looks fine
and the bill does not. Every number above is asserted by a test in `Tests/`.

## The pieces

- `ContextSnapshot` lays a request out as the API hashes it: one block for the tool array, one per
  system segment, one per message, with a cumulative FNV-1a prefix hash on each block and explicit
  breakpoints after the tools and after the system prompt (plus the automatic one on the last message).
- `PromptCache` keys entries by prefix hash, expires them one TTL after last use, refreshes on a hit,
  and walks back at most 20 blocks from each breakpoint looking for a match, per the docs.
- `MissDiagnoser` compares consecutive requests and names the first thing in hash order that broke
  the prefix: tool set, tool order, system segment (by name), a rewritten message, or idle past TTL.
- `SessionSimulator` replays a `SessionScript` and produces a `SessionReport`: hit ratio, tokens
  re-cached, dollars, ideal dollars, and causes ranked by overspend.
- `Fixture` holds the baseline and stabilized afternoons; `ContextCacheDemoView` shows the ledger.

```swift
let report = SessionSimulator().run(Fixture.baseline)
report.hitRatio        // 0.856
report.overspend       // 3.12 dollars over the ideal
report.causes.first    // "tool set changed": 1 turn, 74,412 tokens re-cached, $0.91
```

```swift
// Loading a skill: same tokens, very different cache behaviour.
.loadSkill(name: "skill:networking-layer", tokens: 5_200, placement: .systemPrompt)     // re-sends the transcript so far
.loadSkill(name: "skill:networking-layer", tokens: 5_200, placement: .appendedMessage)  // costs only itself
```

## Run it

```bash
git clone https://github.com/rajatslakhina/prompt-cache-keys-article-demo.git
cd prompt-cache-keys-article-demo
swift test                 # 30 tests
open Demo.xcodeproj        # pick the Demo scheme, any iPhone Simulator, Build & Run
```

No other setup: `Demo.xcodeproj` consumes the library through a local package reference to `.`.

## Verification status

- `swift build`: clean, 0 warnings (Swift 6.0.3, Linux aarch64).
- `swift test`: 30/30 passing.
- `Demo.xcodeproj/project.pbxproj`: hand-authored; braces and parentheses balanced, all 22 object ids
  defined, local package reference, shared `Demo` scheme committed.
- **Simulator run: not performed.** The unattended run that produced this repo could not be granted
  Xcode/Simulator access, so there is no screenshot in `Demo/Screenshots/`. See that folder's README.

## Sources the fixture is calibrated against

- Anthropic, [Prompt caching](https://docs.claude.com/en/docs/build-with-claude/prompt-caching):
  tools → system → messages hierarchy, 5-minute and 1-hour TTLs, 20-block lookback, Fable 5.1
  prices ($10 input, $12.50 / $20 write, $0.25 read per million tokens).
- Claude Code [CHANGELOG](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md), 2.1.250
  through 2.1.261: cache-miss cause reporting in `/cost`, `/skill-doctor`, and the teammate
  re-announcement, OAuth re-render and Remote Control re-send bugs the fixture's events are modelled on.

MIT licensed.
