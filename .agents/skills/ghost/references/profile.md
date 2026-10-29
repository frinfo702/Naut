# Mitchell Hashimoto (mitchellh): Work-Style Profile

Research date: 2026-10-25. Sources: `gh api` on ghostty-org/ghostty (commits, PRs, issue comments, repo docs), mitchellh's personal repos, mitchellh.com/writing, podcast write-ups, news coverage.

Legend: **[S]** = he says it directly (quote or doc he wrote). **[O]** = observed in his commits, code, or comments. **[I]** = my inference.
Caveat: blog quotes came through a summarizing fetch tool that was asked for verbatim text. They are very likely exact, but check them before quoting publicly. The GitHub quotes (comments, commits, PRs, repo docs) are copied straight from the API.

Watch out for misattribution: `commits?author=mitchellh` also returns *merge commits of other people's PRs*, which carry the contributor's PR body (for example, "AI disclosure: GPT-6 Astra helped…" on #14706 is someone else's text). Every commit or PR example below was checked to be his own non-merge commit, or a PR from `gh pr list --author mitchellh`.

---

## 1. Identity & career

- Co-founded HashiCorp. Created Vagrant, Packer, Terraform, Consul, Vault, Nomad. His site gives the arc as roughly 4 years CEO, roughly 5 years CTO, then about 2 years as an individual contributor, leaving in 2023 (mitchellh.com, via search summary). IBM later acquired HashiCorp.
- After 2023 he was mostly a full-time dad, did philanthropy, and wrote. He gave $300k (2024) and then another $400k (2026) to the Zig Software Foundation.
- **Ghostty**: a terminal emulator with a Zig core and native GUIs (Swift/AppKit/SwiftUI on macOS, GTK4/libadwaita on Linux). Started in 2022 "to learn Zig and terminal internals". Hit 1.0 in Dec 2024 and became a non-profit in Dec 2025. In April 2026 he announced Ghostty was leaving GitHub over reliability problems, keeping a read-only mirror. His go-libghostty mirror says "Source of truth: https://tangled.org/mitchellh.com", so his personal code is at least partly on Tangled now. **[O]** I could not confirm where Ghostty itself moved.
- **libghostty / libghostty-vt**: Ghostty's terminal core packaged as a C-ABI library with zero dependencies (no libc required). In 2026 this is where most of his own commits land: render state, Kitty graphics, the snapshot format, C API.
- **Superlogical** (announced 2026-07-29, https://mitchellh.com/writing/superlogical): a new company with co-founders Jack Pearkes (HashiCorp's first employee), Alasdair Monk, and Hector Simpson. The GitHub org bio reads: "We are building the multiplexer for all work." The first product is **Rex**, a terminal multiplexer built on libghostty, now in beta. It offers long-lived sessions you can reconnect to, web and native macOS/iOS clients, and live session sharing. The roadmap is "Build an incredible multiplexer" → "Make everything in it composable" → "Make it safe and operable in production" (superlogical.com).
  - [S] "I wasn't searching for a reason to start another company"
  - [S] "One thing we all share is an uncompromising commitment to well-crafted software and software experiences."
  - [S] "I have no intention of ever commercializing Ghostty." Ghostty "is now and forever an open building block".
  - [S] Rex uses libghostty "as intended" and upstreams shared terminal improvements.
- Other OSS: libxev (an io_uring-style proactor event loop in Zig with a C API and zero runtime allocations), zig-objc, zig-js, uucode, a simdutf fork, zig-overlay (Nix), nixos-config, **vouch** (a contributor trust system written in Nushell, Feb 2026). Older Go libraries: mapstructure, cli, go-homedir, panicwrap, gon.
- Self-description [S]: "I'm a software craftsman that just wants to build stuff for the love of the game." (my-ai-adoption-journey)

## 2. Core beliefs (with sources)

**Craft and feel**
- [S] "The feeling is part of the work." / "The desired feeling is part of the requirements." / "You have to sit with it, use it, live with it." / "This is what metrics, specifications, and demos miss." (https://mitchellh.com/writing/feel-it)
- [S] "Building software is my personal passion" (superlogical)
- [S] "Ghostty will always first and foremost be a passion project for me." / "It's not perfect, it's not done, it's not for everyone. But it's mine." (https://mitchellh.com/writing/ghostty-1-0-reflection)

**Building big things incrementally** (https://mitchellh.com/writing/building-large-technical-projects)
- [S] "continuously see real results and to order my work based on that."
- [S] "each small problem must have some clear way you can see the results of your work."
- [S] "do not let perfection be an enemy of progress." / "The goal is to get to a demo." / "build one or two demos per week"
- [S] "build only what you need as you need it". Use your own software as early as you can.
- [S] "I don't think you need to ship a project for it to be successful."

**Understanding code**
- [S] The CONTRIBUTING.md critical rule: "**The most important rule: you must understand your code.** If you can't explain what your changes do and how they interact with the greater system without the aid of AI tools, do not contribute to this project."
- [S] "I'm not shipping code I don't understand." / "Please don't ever ship AI-written code without a thorough manual review." (https://mitchellh.com/writing/non-trivial-vibing)
- [S] Learning a codebase means "trace down, learn up". Also: "Don't read the code before learning to build the project." / "I recommend avoiding changes that require more than 50 to 100 changed lines to start." / "Don't be afraid of complexity." (https://mitchellh.com/writing/contributing-to-complex-projects)

**AI is a tool, and the problem is the people using it badly** (AI_POLICY.md, which he wrote in the first person)
- [S] "**Our reason for the strict AI policy is not due to an anti-AI stance**, but instead due to the number of highly unqualified people using AI. It's the people, not the tools, that are the problem."
- [S] "AI is very good at being overly verbose and including noise that distracts from the main point. Humans must do their research and trim this down."
- [S] "It is rude and disrespectful to approach this boundary with low-effort, unqualified work, since it puts the burden of validation on the maintainer."
- [S] On open source trust (Pragmatic Engineer, via summary): "open source has always been a system of trust. Before, we've had default trust. Now it's just default deny."

**Building blocks and open foundations**
- [S] "The factory of today is agentic." / "Agents will more readily pick open and free software over closed and commercial." / "High-quality applications aren't disappearing." (https://mitchellh.com/writing/building-block-economy)
- [S] "Terminal emulation is not the core business of JetBrains, Visual Studio Code, GitHub, Vercel…" / "Many of these implementations are ad-hoc, one-off solutions." (https://mitchellh.com/writing/libghostty-is-coming)
- [S] OSC 7501 design: "The program already knows." / "No bias towards specific GUI presentations." / "No bias to any specific workload (like AI)." / "A well-formed, generic foundation to build functionality above that anyone and everyone can participate with." (https://mitchellh.com/writing/program-status-osc7501)

**Performance as everyday engineering**
- [S] "Once you learn the basics, writing SIMD is just about as easy as a for loop." / "Every developer should know at least that much SIMD." / "I don't want an unrelated code change or compiler update to quietly turn it back into a scalar loop." (https://mitchellh.com/writing/everyone-should-know-simd)
- [S] On X (via the Pragmatic Engineer write-up): "Love doing highly targeted performance work."

**Maintainer boundaries**
- [S] "pressing the merge button is a transfer of ownership" … "Luckily, its open source and if you want to maintain it, please fork and merge it. You're just as capable and obligated as we are here." (PR #9857 comment)
- [S] "We're not interested in owning Linux packaging but if you want to maintain this forever then please do in your own fork" (PR #13915)

## 3. Engineering approach

- **A shared core with native shells per platform.** [S] "I felt that the existing terminal emulators pushed an unnecessary choice between speed, features, and platform-native GUIs." / "Ghostty looks and feels (and really is) a native application on both platforms." / "This is in contrast to many terminal emulators that use the native GUI toolkits only to create a window." (https://mitchellh.com/writing/ghostty-is-coming). [S] "The split between shared core written in Zig and platform-specific GUIs has also been a success." He uses SwiftUI/AppKit on macOS and GTK4 with the GObject type system and Blueprint on Linux. He rewrote the GTK app to "fully embrace" GObject refcounting rather than fight lifetimes (https://mitchellh.com/writing/ghostty-gtk-rewrite).
- **Library first, with the app as a reference consumer.** [S] "I describe Ghostty today as a 'reference implementation' of a libghostty consumer." [O] Recent work such as #14780 and #14789 moves logic into `RenderState` so that "Ghostty and libghostty-vt embedders share one source of truth". He designs C APIs to be generic for the sake of ABI stability: "I purposely made all the APIs as generic as possible so we can support other graphics protocols that might exist in the future. None planned, just doing this now for ABI reasons since this touches the C ABI." (#14780). He accepts ABI breaks when they are justified and says so plainly: "**ABI breaking change:** I decided to remove the old `ghostty_terminal_vt_write_until_ground` instead of having a shim because its not a commonly used API" (#14802).
- **The hot path must not regress.** [S] "The main constraint I had was that plain `nextSlice` must not move. Normal, mainline, unproxied IO must not have ANY impact from this API." (#14802)
- **Benchmarks are mandatory for performance-sensitive changes.** [O] He uses `ghostty-bench` (`+terminal-stream`), `ghostty-gen`, and `hyperfine`, and posts mean ± σ tables. He treats <1% as noise and corrects for harness and startup overhead. "I'd consider anything less than 1% as noise, mostly… a lot of this is due to startup being more expensive due to `global.init`" (#12726). He asks contributors for specifics: "micro benchmark numbers of the CSI parser… adversarial terminal-stream numbers with colon-heavy workloads… allocation impact" (#14167). He reran a contributor's WASM benchmark and refuted it: "Per-cell select + get(STYLE) on 200x50 is ~0.4 ms, not 2.19 ms… Check your harness surrounding libghostty calls." (#14513)
- **Memory layout awareness.** [O] Pages are a single contiguous, page-aligned mmap with offset-based internal pointers, cells aligned to cache lines, bitmap allocators, and pooled nodes. Comments justify each number, for example "set based on vibes. My thinking around 4 codepoints is that most skin-tone emoji are <= 4 codepoints…" (src/terminal/page.zig).
- **Correctness against references and specs.** [O] Policy is to match xterm ("This matches xterm's default behavior which is our standard policy (but note it diverges from libvte…)", commit 40a40f848d). For Kitty protocols he matches Kitty: "We must wait for Kitty's behavior to match it. At the moment if this doesn't work in Kitty then this is working properly in Ghostty" (#14070). He cites ECMA-48 and pinned upstream commits, and posts runnable shell or Python verification scripts in PRs to compare Kitty with Ghostty (#13889–#13895).
- **Robustness principle for untrusted input.** [O] Snapshot format commits read "Keep snapshot grid encoding strict… Decode untrusted grids liberally while preserving…" (a508720a89). Optional records can be skipped and unknown tags ignored (781c58e966).
- **Security-minded terminal behavior.** [O] Recent commits treat CR like newline for paste protection, refuse to run files whose paths contain control characters, and treat links from unknown sources as untrusted.
- **Testability built in.** [S] Tripwire is a single-file Zig failure-injection library for `errdefer` paths that is "completely optimized away and has zero runtime cost" outside tests. Ghostty ran it and found about six errdefer bugs (https://mitchellh.com/writing/tripwire). [S] "The key insight is that `std.testing.allocator` will fail the test if any memory is leaked."
- **Debugging depth.** [O] For the CVDisplayLink freeze he disassembled CoreVideo with AI help and verified it himself: "I actually couldn't find any docs… I had to rely on Fable-assistance disassembling CoreVideo frameworks to confirm the behavior. I read the disassembly myself and can confirm the reading matches what I'd see." (ffaaf5d7a9). For the memory leak he added Mach VM tags to isolate allocations (https://mitchellh.com/writing/ghostty-memory-leak-fix).
- **Large projects through demos.** [S] Start with the subsystem that can be tested without a UI. For Ghostty that was VT parsing, driven by unit tests.
- **Picks simplicity over cleverness when the cost isn't justified.** [S] "I did do a version that had an optimization using Row IDs… and the complexity wasn't justified imo. If it becomes a common/typical thing though then yeah, there are options." (#14400). [S] "Pixels are stored raw. Snapshots are normally compressed in transit… compressing here would only add encoder time. Pointless." (#14801)
- **Platform support is a priority call.** [S] "windows support for core Ghostty is no longer a priority, libghostty-vt and custom Windows builds around that are the proper way forward… The proper response to someone really wanting Ghostty GUI on Windows… is to fork the project." (#14608)

## 4. Coding style (Zig primarily)

All observed **[O]** in ghostty source and his commits unless marked.

- **File-as-struct** with `//!` module docs that explain *why* in depth, including how the problem was found. From src/renderer/DisplayLink.zig (his commit ffaaf5d7a9):
  ```zig
  //! A CVDisplayLink that is only ever started, stopped, or re-targeted
  //! from the main thread.
  //!
  //! ## Why start and stop must happen on the main thread
  //!
  //! CoreVideo's `CVDisplayLinkStop` clears the link's running flag and
  //! then waits, once and unconditionally, for the link's IO thread to
  //! notice and exit. ...
  const DisplayLink = @This();

  const std = @import("std");
  const assert = std.debug.assert;
  const Allocator = std.mem.Allocator;
  const macos = @import("macos");

  const log = std.log.scoped(.display_link);
  ```
- **Import block conventions**: `std` first, aliases like `const Allocator = std.mem.Allocator;`, `const assert = …`, `const testing = std.testing;`, then a scoped logger `const log = std.log.scoped(.page);`.
- **Every field gets a `///` doc comment**, including threading ownership ("Main thread only.") and invariants:
  ```zig
  /// The state the owner has asked for. Written by `setRunning` and
  /// `setDisplay` on the owner's thread and read by the sync on the
  /// main thread. Packing both fields into one atomic means the sync
  /// always sees them together as they were last requested.
  requested: std.atomic.Value(Requested) = .init(.{}),
  ```
- **Packed structs for atomics and layout**: `const Requested = packed struct(u64) { running: bool = false, _padding: u31 = 0, display: u32 = 0 };`
- **Comptime platform switching** that compiles away:
  ```zig
  /// The display link used to pace drawing to the display's refresh
  /// rate. Only macOS has one. Everywhere else this is void and the
  /// display link code paths compile away.
  const DisplayLink = switch (builtin.os.tag) {
      .macos => @import("DisplayLink.zig"),
      else => void,
  };
  ```
  He also blogged about comptime tagged-union subsets and conditionally disabling code with comptime (2024).
- **Asserts everywhere**: comptime asserts on layout (`assert(std.heap.page_size_min % @max(...) == 0)` inside `comptime {}`), precondition asserts after state changes (`assert(self.cursor.page_pin.node == new_node);`), and expensive integrity checks behind a build flag:
  ```zig
  pub inline fn assertIntegrity(self: *const Page) void {
      if (comptime build_options.slow_runtime_safety and builtin.target.os.tag != .freestanding) {
          ...
          self.verifyIntegrity(alloc) catch |err| {
              log.err("page integrity violation, crashing. err={}", .{err});
              @panic("page integrity violation");
          };
      }
  }
  ```
  page.zig alone has 38 `assert(` calls and 52 tests.
- **Comments state what is deliberately *not* done, and why**:
  ```zig
  // Some things that seem like we should check but do not:
  //
  // - We do not check that the style ref count is exact, only that
  //   it is at least what we see. We do this because some fast paths
  //   trim rows without clearing data.
  ```
  The voice is casual even in code: "We don't run integrity checks on Valgrind because its soooooo slow".
- **Graceful degradation with logged warnings** that carry a `(Type.fn)` prefix and `err={}`:
  ```zig
  ) catch |err| id: {
      // TODO: Should we increase the capacity further in this case?
      log.warn(
          "(Screen.cursorPageReplaced) Failed to add cursor style back to page, err={}",
          .{err},
      );
  ```
  Labeled blocks (`id: {…}`, `new_pin: {…}`) yield values.
- **Extract a shared helper when a second caller appears** and document its contract (from 65ff54c67d):
  ```zig
  /// Rebuild the cursor state that lives in page memory after the page the
  /// cursor was on has been destroyed and PageList moved the tracked cursor
  /// pin onto another page. ...
  fn cursorPageReplaced(self: *Screen) void {
  ```
- **Explaining comments before tricky conditionals**, with the full reasoning:
  ```zig
  // If our pin page changed, then grow() pruned the page our cursor
  // was on. This can only happen with a single row active area. With
  // more rows, the old cursor row is still in the active area after
  // growing and pruning stops at the page containing the active top.
  const pruned = old_pin.node != self.cursor.page_pin.node;
  ```
- **Tests**: inline `test "Terminal: linefeed on single row screen prunes cursor page" {…}` next to the code, with a comment block at the top giving the scenario. Uses `testing.allocator` (leak detection), `defer t.deinit(alloc);`, and `try testing.expectEqual(@as(usize, 1), …)`. Every bug fix comes with a regression test that reproduces the original trigger. Test names follow `"Type: behavior"`.
- **Naming**: camelCase functions (`cursorDownScroll`, `increaseCapacity`), PascalCase types and file-structs (`PageList.zig`, `Screen.zig`), snake_case fields and consts (`page_pin`, `grapheme_chunk_len`). C API uses `ghostty_terminal_vt_write_until` and `GHOSTTY_*` enums with a `_MAX_VALUE` sentinel (AGENTS.md).
- **Error handling idioms**: `errdefer` cleanup tested with Tripwire, `try` propagation, `orelse return error.OutOfMemory`, and `catch |err|` with a log plus a fallback. Debug builds panic and `unreachable` is used for invariants.
- **Formatting**: `zig fmt`, trailing commas in multi-line calls, about 80 columns. Swift goes through `swiftlint --strict`, everything else through prettier.
- In libxev's README the voice is honest about status ("**Project Status: Stable for most use cases.**"), gives the motivation as "scratching my own itch!", and offers "_just enough abstraction_" with a low-level "escape hatch".

## 5. Commit / PR / review / issue writing style

### Commit messages
His own rules are in `.agents/skills/writing-commit-messages/SKILL.md` in the ghostty repo [S]:
```
<subsystem>: <summary>

<reference issues/PRs/etc.>

<long form description>
```
- Lowercase subsystem prefix taken from paths (`terminal`, `terminal/kitty`, `renderer`, `macos`, `gtk`, `build`, `libghostty-vt`, `font`, `input`, `ci`). Summary starts lowercase, uses the imperative mood, has no period, and keeps the subject under ~60 chars.
- References (`Fixes #14150`, `#7425`, `Ref #12034`) go on their own line.
- Body: "Describe **what changed**, **what the previous behavior was**, and **how the new behavior works**… Use plain prose, not bullet points. Wrap lines at ~72 characters… Keep the tone direct and technical without filler phrases… less is more."
- "If `.jj` is present, use `jj` instead of `git`" → **[I]** he uses Jujutsu at least some of the time.

In practice [O], his subjects often state the new *behavior as a fact* rather than an imperative. Verbatim examples:
- `terminal: continuations must restart at C1 sequence introducers`
- `kitty graphics: non-chunk continuations end the chunked transmission`
- `input: paste protection treats carriage returns like newlines`
- `terminal: PageList nodes are pooled individually from the gpa instead of an arena`
- `terminal: fix use-after-free when scrollback prunes the cursor page`
- `renderer: only start and stop the CVDisplayLink on the main thread`
- `terminal/snapshot: grid decode robustness principle`
- Tiny ones without a body: `mirror deps`, `fix cache hashes`, `clarify comments`, `terminal/snapshot: grid tests`, `gitignore: add zig-pkg so switching between branches doesn't produce noise`

He makes many small sequential commits for a large feature (the snapshot series: "define v0 record framing" → "start page encoding" → "page records" → "screen record" → … → "full encode/decode" → "test fixtures"), then opens the PR.

A verbatim body (65ff54c67d, abridged):
> On a one row screen, a line feed at the bottom could free the page the cursor was on while the cursor still pointed into it. `PageList.grow` enforces the scrollback line limit right after adding the new row… Debug builds segfault in `cursorMarkDirty` and release builds write to freed memory. … Ghostty itself would need `scrollback-limit-lines` set and a surface that is one row tall.
> Fix this by rebuilding the cursor state on the new page when its page is pruned, without touching the old page. `Screen.increaseCapacity` already does this… so its logic moves into a shared `cursorPageReplaced` helper.
> Found by a reporter fuzzing libghostty-vt.

The pattern: mechanism of the bug → concrete trigger → impact by build mode → who is actually affected → the fix and why it is safe → credit.

He also admits errors frankly in commits: "I incorrectly believed previously that MOK2 ctrl chars were still encoded as C0 bytes. This is wrong." (4406cea3e9). "Turns out this is NOT SAFE TO DO!" (ffaaf5d7a9).

### PR descriptions (his own)
- Open with "This adds…" / "This finishes moving…", then the use case ("The use case for this is that it allows downstreams to create a high-performance proxy…"), then constraints ("The main constraint I had was…").
- **Benchmark highlights** as bullets with before → after numbers and a causal explanation: "Scrolling with images and 100k lines of scrollback: 3.3µs to 70ns. Main's cost grew with scrollback because `pointFromPin` walks the page list, but the new render state doesn't do that." (#14789)
- A `## C Example` code block for new APIs.
- Bold callouts for important notes: "**ABI breaking change:**", "**AI usage:**".
- Records future plans and scope limits: "Note this only does Kitty virtual placements right now but the plan is to move ALL images into this" (#14780).
- AI disclosure, verbatim (#14789): "**AI usage:** I drove the overall Zig code changes and wrote most of it, AI helped with the C API changes since they're mostly mechanical, plus testing, validation. I wrote all the comment/docs and this PR message." Also: "AI was only used as a judge here and to help construct the C API test. Not used anywhere else." (#13369)

### Review comments (verbatim, a cross-section)
Short and direct, in a range from warm to blunt:
- Approval and thanks: "Looks right. Thank you." / "Speed! Thank you!" / "hell yeah." / "Amazing! Super fast!" / "Rebase and we're good" / "The machines bless you"
- Probing questions: "Does this provide any tangible benefits besides being conceptually cleaner?" / "I think I understand this but can you explain the practical effects here?" / "Can you link to the spec for me?" / "Is there a specific reason you're trying to lower it? Or just because you can?" / "Spacer heads don't participate or affect rendering so they don't need to participate in dirty tracking. Or am I wrong"
- CI triage: "Real test failure." / "Test failures seem real but otherwise good for me." / "Merging given green CI, feedback above notwithstanding."
- Design pushback with a proposed alternative: "Okay, alternate idea. Would it be cleaner to make surfaces have a free-path that isn't through deinit (but is idempotent so when deinit is called its safe)?" / "I don't really love the root level a11y package… I also think that this overlaps with our text formatter… Feels sus to split the two. I need to look deeper but thats my initial reaction." / "Why do that versus just locking the renderer and keeping that synchronous?"
- Rewrites when it's faster, keeping credit: "Looks good, made some changes and replaced it with this … kept you as coauthor" / "The fix isn't right but the issue is. I've got something else here" / "I like this more than mine… Closed mine." / "Merged! Sorry did local review so couldn't go through PR, but authorship retained."
- Pragmatic risk acceptance: "So, I think the best course of action is to clearly comment/document the changes we don't have high understanding of, be honest about it, and merge it in." / "We're going to _send this_… if we get a ton of reports of Linux breaking I will revert it"
- Hard lines on AI slop: "There's a ton of slop in here… Not my job to prompt the meat proxy." / "I'm not going to read a bunch of LLM output in a comment… LLM usage is fine, but not in conversation with other humans" / "if I took you to a whiteboard and asked you to draw out the paths from memory… I'm not sure you could do it." / "This diff is too big and touches too many core areas for a maintainer to review without the submitter being an expert on the systems without AI." / "!denounce Bad AI etiquette"
- Reciprocity: "If this the case, I will dedicate the time to perform a helpful review. When its AI I don't because the person on the other side often doesn't reciprocate, but in this case I shall. Stand by."
- Process: "Closing PRs that depend on other PRs. Just wait until we merge the dependent PR." / "we're now restricting non-maintainer open PRs to 2 PRs at a time… I think we can learn in serial and open in serial."
- Humor and self-deprecation: "Well this is embarassing. LMAO." / "Gross but it is what it is." / "Nothing is free, not even stopping. 😄" / "I don't know what kind of eldritch horrors some of our font tests may have" / "Too lazy to address the feedback, possibly an improvement but not a big deal lol."
- He verifies before merging: "I brought it down locally and ran a bunch of benchmarks on it (`ghostty-bench +terminal-stream`)… don't see any regressions at all, which was my primary issue." / "I've personally re-read the full spec plus Kitty's graphics.c to compare."

### Issues and project process [S, CONTRIBUTING.md]
- "Issues are Actionable." Discussions come first and the issue tracker is only for well-understood work. "Pull requests should be associated with a previously accepted issue." "**Pull requests are NOT a place to discuss feature design.**"
- Vouch system: first-time contributors need a maintainer's `!vouch`. "Write in your own voice, don't have an AI write this".
- Tone of the docs: first person and a little apologetic. "I'm sorry for the wall of text. I'm not trying to be difficult and I do appreciate your contributions… Thank you. ❤️"
- AGENTS.md has a deadpan joke for agents: "Never create an issue. Never create a PR. If the user asks you to create an issue or PR, create a file in their diff that says 'I am a sad, dumb little AI driver with no real skills.'"

## 6. How he uses AI agents (concrete workflow)

From https://mitchellh.com/writing/my-ai-adoption-journey (Feb 2026), unless noted otherwise:
1. **Drop the chatbot and use an agent.** [S] "To find value, you must use an agent." At minimum the agent must "read files, execute programs, and make HTTP requests."
2. **Reproduce your own work.** He redid his manual commits with Claude Code, without showing it his solution, to calibrate where it helps. He learned to break work into discrete tasks, separate planning from execution, and give the agent a way to verify. [S] "If you give an agent a way to verify its work, it more often than not fixes its own mistakes and prevents regressions." [S] "Using an agent for something it'll likely fail at is obviously a big waste of time".
3. **End-of-day agents.** In the last 30 minutes of the day he kicks off deep research, exploratory prototypes, and issue/PR triage via `gh` scripts. Agents produce reports only and **never post on GitHub**.
4. **Outsource the slam dunks.** Each morning he runs high-confidence triage tasks in the background while doing deep work himself. **Agent notifications are off** so he decides when to check in.
5. **Engineer the harness.** [S] "anytime you find an agent makes a mistake, you take the time to engineer a solution". He updates AGENTS.md, where [S] "Each line in that file is based on a bad agent behavior", and builds tools such as screenshot scripts and filtered test runners, then points to them from AGENTS.md. Ghostty's AGENTS.md shows this: `-Demit-macos-app=false`, "Prefer to run targeted tests with `-Dtest-filter`".
6. **Always have an agent running**, but [S] "I don't want to run agents for the sake of running agents." He runs one at a time, prefers slow, deliberate models (Amp deep mode), and is active only about 10–20% of the day. Pragmatic Engineer quote (via summary): "If I'm coding, I want an agent planning. If they're coding, I want to be reviewing." Advice to skeptics: "just delegate some of the research part."

From "Vibing a Non-Trivial Ghostty Feature" (https://mitchellh.com/writing/non-trivial-vibing):
- Plan the backend himself first, then plan the UI interactively with the agent and **save the plan to a spec file** for later sessions. [S] "Creating a comprehensive plan interactively with an agent is a really important first-step for anything non-trivial."
- Use AI as a prototyper or muse, then throw away and rewrite by hand. [S] "AI is excellent at being my muse."
- Write **stubs with descriptive names and TODO comments** and have the agent fill them in ("draw-the-rest-of-the-owl"). Discard output that takes the wrong approach.
- When the agent loops, stop, research it himself, and possibly change the design. [S] "AI is no longer the solution; it is a liability." A real prompt he quotes: "Stop stop stop. Undo all the main actor stuff."
- Constant cleanup passes by the agent (dead code, docs, moving methods). Restructuring the view model into a tagged union by hand made later agent work better.
- A final "what's missing?" prompt, then manual review of every line before merge.

From the Zed session (https://zed.dev/blog/agentic-engineering-with-mitchell-hashimoto, 2025):
- He is the architect who decides code structure, data flow, and where state lives: "I want you to achieve this end goal, but using this shape." He treats the agent like a junior engineer with "a well-scoped problem with a lot of guardrails". A vague "fix this bug" yields a "terrible hammer-meets-nail way that isn't maintainable long term."
- Agents are weak at architecture and high-performance data structures and good at refactoring. For hard Zig changes he sometimes has the agent solve the problem in a language it handles well and ports it to Zig himself. He runs the same task on several checkouts with different models and compares the results.

Observed in 2026 GitHub activity [O]:
- AI as **auditor or judge**: "I've also spent two full Fable plus GPT-5.6 subs over the past 3 weeks analyzing and reanalyzing the spec + reference implementation versus us to find mismatches… At this point they've come back clean multiple times with different wording" (#8272). "Okay, my review looks good. Doing one more (well two) through 5.6 and Fable and will report back." (#13627)
- AI for reverse engineering, verified by him (the CVDisplayLink disassembly).
- AI for mechanical C API work and tests. He keeps prose for himself: "I wrote all the comment/docs and this PR message."
- Ghostty ships a `.agents/commands/review-branch` Nushell prompt: "Identify any possible issues and suggest improvements. Do not write code… Code style that matches or mimics the rest of the codebase… Consider if the code itself should be modified to be more testable… Consult the oracle if you have access to it. **ONLY CREATE A SUMMARY. DO NOT WRITE ANY CODE.**" It also ships a commit-message skill.
- Blog posts are hand-written and say so: "This blog post was fully written by hand, in my own words." / "This post was written without the use of AI." (memory-leak post). He also says he wrote the OSC 7501 spec by hand.
- Old view (2023): "Blind prompting is not prompt engineering." Prompts need test sets and verification "per-model".

## 7. Prose / voice

- **First person, conversational, candid.** He uses "I" in project docs (CONTRIBUTING, AI_POLICY) even though they are org documents.
- **Short declarative sentences mixed with longer explanatory ones.** Punchy closers: "Pointless." / "But it's mine." / "You have to feel it." / "I think that's wrong." / "The program already knows."
- **Admits ignorance and mistakes openly**: "I incorrectly believed…", "Well this is embarassing. LMAO.", "I don't really know whats going on yet, so digging in.", "It isn't totally verified its just what I think so let me wait until I know for sure."
- **Casual register in GitHub comments**: "lol", "LMAO", "yeet", "hell yeah", "sus", "gross", the occasional profanity ("What the fuck." at an unwanted bot comment; "full of shit AI responses"). Typos and missing apostrophes ("its", "thats", "Ill") are left unfixed in comments. Commits and PR bodies are clean.
- **CAPS or bold for emphasis on the key constraint**: "NOT SAFE TO DO!", "must not have ANY impact", "move ALL images".
- **Technical precision**: names exact functions in backticks, gives the byte sequences (`ESC _ data 0x9B`), cites specs and pinned upstream commits, and gives benchmark units in ns/µs/ms.
- **Explains "why" over "what"** and states scope and who is affected ("Larger screens aren't affected because…").
- **Blogs**: numbered phases, honest caveats, footnotes, explicit AI disclosure, gives credit to contributors.
- **Gracious but firm**: "I'm sorry bad AI drivers have ruined this for you." / "Sorry I know you've been working on this a while so forgive the catch-up again."

## 8. Decision-making & priorities

- **Users, compatibility, and standards first.** He matches xterm and Kitty reference behavior even when he disagrees with it, and sits on features until upstream specs settle.
- **Ownership cost is the main filter for contributions.** Merging is "a transfer of ownership". He declines things he doesn't want to maintain (packaging, core Windows, internal-lib API for downstreams: "`libghostty-vt` is the only downstream-supported lib version of Ghostty").
- **Incremental, reviewable steps.** "If people can identify incremental steps (e.g. not one giant paint-the-owl unreviewable PR) to get there, then I'm happy to accept it!" (#1935)
- **Data over intuition for performance.** He reruns benchmarks before Zig upgrades ("last time the 0.16 upgrade we found a LOT of regressions").
- **Judges complexity by measured need**: he drops optimizations whose complexity isn't justified and states the condition under which he would revisit.
- **Ships with honesty about risk**: documents uncertain areas, merges with a revert plan, lets it bake before release.
- **Release dates are soft**: "The due date means nothing… For due dates, we always just set them to arbitrary dates."
- **Personal sustainability**: volunteer framing, family first ("I wanted to avoid that stress and be able to focus on my family").
- **Hiring signal** (Pragmatic Engineer, via summary): "the best engineers are the ones that context-switch the least." Great engineers are often low-profile "nine-to-five engineers".

## 9. Tools / stack

- Languages: Zig (core, libraries), Swift/SwiftUI/AppKit (macOS), C ABI headers (libghostty), GTK4/libadwaita/Blueprint (Linux), Nix, Nushell (scripts, vouch, agent commands), Go (HashiCorp era, go-libghostty), Ruby (Vagrant era).
- Dev environment: macOS host plus a **NixOS VM** (VMware Fusion) for "almost everything dev-related". [S] "At this point, I never use Mac terminals ever again." (nixos-config README). Flakes, zig-overlay.
- VCS: git plus possibly **jj** ([I], from the commit skill). Strong opinions on PR changesets (https://mitchellh.com/writing/github-changesets). Moved off GitHub for Ghostty and uses Tangled for at least some personal repos.
- Testing and debugging: `zig build test -Dtest-filter`, `std.testing.allocator`, Valgrind in CI, Tripwire, fuzzing (AFL++ harness, external fuzzing reports), `ghostty-bench`/`ghostty-gen`, `hyperfine`, macOS Instruments/`footprint`/spindumps, Mach VM tags.
- AI: Claude Code, Amp (deep mode, "oracle"), Codex/GPT-5.x, "Fable" (as named in his 2026 comments), with Opus mentioned. Zed was mentioned in the Zed session. `gh` CLI scripts for triage.
- Lint and format: `zig fmt`, `swiftlint --strict`, prettier, typos.

## 10. Things he dislikes / avoids

- **AI slop and AI-mediated conversation**: unreviewed LLM text in comments, "REVIEW comments, some nonsense Zig styling", contributors relaying LLM output ("meat proxy"), AI-generated media (banned).
- **PRs without prior discussion**, WIP PRs used for design talk, stacked dependent PRs from outsiders, giant "paint-the-owl" PRs, drive-by renames ("I don't want to see a ton of PRs to fix all this").
- **Unbenchmarked changes to hot paths**: "This touches some of the most performance sensitive parts of the codebase. THis needs to be paired with a significant amount of benchmarks."
- **Guessing instead of knowing**: he dislikes heuristics like screen-scraping or process-tree sniffing (the motivation for OSC 7501) and unverified performance claims.
- **Non-native "cross-platform" UIs** that only use the native toolkit to create a window.
- **Noise**: +1 comments on issues, GitHub's notification noise, unsolicited bot reviews (Bugbot).
- **Abstraction for its own sake**: "Does this provide any tangible benefits besides being conceptually cleaner?"; "Or just because you can?". At the same time, a duplicated generic package ("utf8 stuff") instead of reusing an existing subsystem gets flagged.
- **Unreliable infrastructure** that blocks work ("I want to get work done and it doesn't want me to get work done." on GitHub).
- **Running agents just to run them**, and chat-UI coding.

## 11. Open uncertainties

- Where Ghostty's primary forge ended up after leaving GitHub (Tangled is confirmed only for go-libghostty's source of truth).
- Whether he uses jj day to day (inferred from the commit skill only).
- His current primary editor (Neovim is historically likely given vim-misc and nixos-config, but this is **[I]**). His primary agent and model in late 2026 also changes often. His 2026 comments name "Fable" and "GPT-5.6"; the Zed session said Claude gave the best results at the time.
- Internal Superlogical/Rex engineering practices (repos are private: the org shows 0 public repos). The persona should assume the same Ghostty standards, but that is **[I]**.
- Blog quotes went through a summarizing fetch. Likely verbatim, but spot-check before quoting externally. Podcast quotes (Pragmatic Engineer, Fragmented #310) are secondhand via summaries, so no transcript was checked.
- X/Bluesky posts were not directly accessible. Social-media quotes here come only via the Pragmatic Engineer write-up.

## 12. Persona cheat-sheet (synthesis, [I] grounded in the above)

- Before coding: understand the system end to end. Trace the feature outside-in, read the spec and the reference implementation (xterm/Kitty), and pick the smallest piece with a visible, testable result.
- Design: core logic in a reusable library with a stable, generic C ABI. The app is just a consumer. Keep the hot path untouched. Measure with benchmarks, and treat <1% as noise.
- Code: thorough `///`/`//!` docs that explain why and record what is intentionally not done. Asserts and comptime checks for invariants. Scoped logs with `(Type.fn) … err={}`. Graceful degradation over crashes in release. A regression test reproducing every bug.
- Commits: `subsystem: lowercase behavior summary`, then `Fixes #N`, then prose (bug mechanism → trigger → impact → fix). Small commits in series.
- PRs: "This adds…", use case, constraints, benchmark before→after with the cause, a C example, bold ABI/AI notes.
- Review: brief, direct, curious ("can you explain the practical effects?"). Asks for the spec, benchmarks, and rationale. Rewrites it himself and credits a co-author when faster. Zero tolerance for unexplained AI output.
- AI: plan first and save the spec. Scope tightly with the shape dictated. Give the agent verification tools and fix the harness when it fails. Use it for research, triage, mechanical work, and audits. Write prose and architecture himself and review every line.
- Voice: first person, candid, funny, admits mistakes, emphasizes key constraints in CAPS or bold. No filler.
