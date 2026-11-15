# AG-UI in Emacs: embr.el's native canvas, and self-hosting CopilotKit Intelligence

Research note, 2026-11-15. Local facts were checked against a2ui.el at
commit 6253eae (`/Users/chazu/dev/elisp/a2ui.el`) and against the Emacs
installed on this machine. External sources were read on the date above.

## Summary

**Question 1: embr.el for AG-UI. Not now; probably never as the main
path.** embr.el is a web browser: a headless Chromium whose frames Emacs
shows as an image. Native canvas only makes those frames faster to blit. It
is not a component toolkit, and embr has no documented Emacs-to-page API.
Using it for AG-UI would move the AG-UI client and the UI into a web app
that Emacs only displays as pixels. You would lose what a2ui.el gives you
now: text you can search and copy, your theme, normal editing keys, and
"nothing the agent sends is evaluated as code". Extend a2ui.el's own client
(option a) instead. A hybrid, with embr as the viewer for URLs an agent opens,
already works without code, because a2ui.el opens URLs with `browse-url`.
Look again only if an agent needs web-only UI that has no A2UI equivalent,
and after Emacs 32 ships canvas on macOS.

**Question 2: self-hosting CopilotKit Intelligence. No.** Intelligence is
a licensed storage, analytics and learning layer behind the CopilotKit
runtime: threads, replay, memories, analytics and channels. It does not host
agents, and A2UI does not depend on it. Self-hosting means Kubernetes,
Postgres, Redis and OIDC, or a 30-day local evaluation that needs an account.
It would also make things worse for Emacs: with Intelligence enabled, the
runtime's run endpoint returns JSON and streams events over a websocket, which
a2ui.el's curl/SSE client cannot read. The things that do help Emacs (an
AG-UI endpoint, routing between agents, the A2UI middleware) are in the
MIT-licensed CopilotKit runtime, which does not need Intelligence. It is
worth running that runtime only if you need one URL in front of several
agents.

## What exists today in a2ui.el

From `a2ui-agui.el`, `DESIGN.md`, `README.md` and `test/a2ui-agui-test.el`:

- **Transport.** A curl subprocess POSTs a `RunAgentInput` and reads an SSE
  stream, one process per run. Agents are configured in `a2ui-agui-agents`
  (name, URL, headers, and auth from authinfo).
- **Event reducer.** RUN_*, TEXT_MESSAGE_* (including CHUNK), TOOL_CALL_*,
  TOOL_CALL_RESULT, STATE_SNAPSHOT/DELTA (applied with an RFC 6902 patcher),
  MESSAGES_SNAPSHOT and ACTIVITY_SNAPSHOT/DELTA of type `a2ui-surface`. Other
  events, including REASONING_*, are ignored.
- **Where A2UI comes from.** Calls to the frontend tool `render_a2ui`, which
  the client declares in every run; middleware activity events; and tool
  results that carry `a2ui_operations`. The client also sends the catalog
  digest as context, sends render validation errors back (retried up to
  `a2ui-agui-render-retries` times), and answers actions as
  `log_a2ui_event` or, with the `forwarded-props` encoding, the way
  CopilotKit's middleware expects.
- **Interrupts.** A RUN_FINISHED with `outcome.type = "interrupt"` becomes one
  surface per interrupt with Approve and Reject buttons. Once every interrupt
  has an answer, the client resumes with
  `{status:"resolved", payload:{approved:bool}}`. It ignores `responseSchema`,
  and a rejection is sent as `resolved` with `approved:false`, not as
  `cancelled`.
- **Gaps, as of this commit.** Shared state is stored but never shown. No
  frontend tools other than `render_a2ui` are declared. Over AG-UI, only the
  render tool is exposed (README), so save, recall and update are not
  available there. There is no reconnect or `connect`, and no thread
  persistence across Emacs sessions. AG-UI interrupts don't count as
  "waiting" (DESIGN.md).

## Question 1: embr.el's native canvas rendering and AG-UI

### What it is

- **embr.el is a web browser running inside Emacs.** "Emacs handles display
  and input; a headless Chromium renders pages." The browser is CloakBrowser,
  a Chromium build whose anti-fingerprinting patches are closed source (the
  default), or Playwright's Chromium. A Python backend (`embr.py`) drives it
  over CDP and streams frames by screencast. Keys go to the page, except
  `C-x` and `M-x`. The package is GPL-3.0 and needs Emacs 30.1 or later and
  Python 3.10 or later. Linux is the main target; macOS "has been reported to
  work". ([embr.el README](https://github.com/emacs-os/embr.el))
- **Native canvas is a faster way to show frames, nothing more.** On Emacs 32
  with canvas images, embr builds a C module, `native/embr-canvas.so`, that
  writes each frame into an image's pixel buffer. Without canvas, it writes a
  JPEG file for every frame. embr's own benchmark, run on a pre-merge patch,
  measured 30–35% lower input-to-frame latency (p50 10.0 ms against 14.4 ms)
  at about the same frame rate (~34.6 against ~33.9 fps).
  ([README](https://github.com/emacs-os/embr.el)) Canvas is not a browser
  engine, a DOM, or a widget layer. It is a writable ARGB32 pixel buffer shown
  as an image. ([bug#80281](https://debbugs.gnu.org/cgi/bugreport.cgi?bug=80281))
- **Upstream status.** Daniel Mendler requested canvas in bug#80281
  (29 January 2026). Divya Ranjan's revised patch was approved by Alan Third,
  and Eli Zaretskii closed the bug on 16 August 2026: "this is now installed
  on the master branch".
  ([bug#80281](https://debbugs.gnu.org/cgi/bugreport.cgi?bug=80281);
  [Emacs News 2026-08-17](https://sachachua.com/blog/2026/08/2026-08-17-emacs-news/))
  embr's README says canvas was mainlined in July 2026, which disagrees with
  the bug log. The API in the reviewed patch is an image of `:type canvas`, a
  Lisp function `canvas-refresh`, and a module function `canvas_data` that
  returns the pixel buffer. I saw that API in the patch discussion and a
  [mirror](https://codeberg.org/monadicsheep/emacs) of the commit, not in the
  official repository or NEWS, so the names could still change before
  release. The patch author said it was tested on PGTK, X11, Lucid, macOS and
  Windows; I couldn't confirm how well the NS (macOS) path works in the
  merged version.
- **Can you use it on this machine today? Not the canvas part.** Both
  Homebrew's `/opt/homebrew/bin/emacs` and `/Applications/Emacs.app` are
  31.1 NS builds. In both, `canvas-refresh` is unbound and `canvas` is not in
  `image-types`; MODULES and RSVG are present, XWIDGETS is not (checked
  2026-11-15). To get canvas you would need to build Emacs master (32.0.50).
  embr itself would still run on 31.1 through its JPEG fallback.
- **Maintenance.** 83 stars, 4 forks and 262 commits. Activity comes in
  bursts, from April to 4 November 2026, by two main contributors. There are
  no releases. The README says it was built with Codex 5.3 and Claude Opus 4.6.
  ([repo](https://github.com/emacs-os/embr.el);
  [commits](https://github.com/emacs-os/embr.el/commits/master))

### Where embr could fit with AG-UI

AG-UI "is not a generative UI specification"; it is a "bi-directional
runtime connection between the agent and the application", and it carries
A2UI and other UI specs.
([AG-UI: generative UI specs](https://docs.ag-ui.com/concepts/generative-ui-specs))
So embr could only play one part: **the display surface for a web front
end**, such as a CopilotKit React app or a page with `@a2ui/react`, served on
localhost. In that design, the AG-UI client runs in the page's JavaScript and
Emacs only shows pixels and forwards keys. The embr README documents no way
for Lisp to evaluate JavaScript in the page or receive events from it; it
only offers `embr-browse URL`. Feeding AG-UI events from Emacs into the page,
or getting actions back, would mean adding a bridge to embr or to the web
app, for example a websocket to an Emacs server.

The three options:

- **(a) Extend a2ui.el.** Keep the client and the native vui renderer, and
  close the gaps listed above.
- **(b) embr renders a web UI.** A localhost web app runs the AG-UI client;
  embr shows it in an Emacs window.
- **(c) Hybrid.** a2ui.el stays the client and renderer; embr shows only
  content that A2UI can't express (a URL, rich HTML, an MCP-UI resource).
  Basic form: set `browse-url-browser-function` to `embr-browse` (the README
  suggests this). a2ui.el's `openUrl` goes through `browse-url` after
  confirmation (`a2ui-core.el`, `a2ui-open-url`), so this needs no code.

| | (a) Extend a2ui.el | (b) embr + web UI | (c) Hybrid |
|---|---|---|---|
| Who speaks AG-UI | Emacs (curl/SSE), already built | JavaScript in the page; Emacs is not a party | Emacs |
| Keyboard and editing | Normal buffer text: TAB/RET, kill ring, isearch; long text edited in its own buffer | Keys go to Chromium; `C-x`/`M-x` still reach Emacs; no Emacs editing inside web fields; text is pixels | Native for surfaces; browser rules inside embr |
| Theming | Faces from your theme, including status tones | Page CSS; optional Dark Reader extension | Mixed |
| Accessibility | Buffer text, available to Emacs screen readers | Pixels; embr documents no accessibility support, only "View text" and "Reader" in a menu | Native parts readable |
| Performance | Text redisplay; no extra process | A Chromium and a Python process; ~30–35 fps cap with or without canvas | Chromium only when opened |
| Security | Agent output is declarative; never evaluated; URL opens ask first | Runs arbitrary web JavaScript inside a closed-source Chromium build by default; the web app and its npm dependencies are trusted code | Web content only behind an explicit, confirmed open |
| Dependencies | vui.el, curl ≥ 7.76 | Python venv, Chromium binary, Node toolchain for the web app; C compiler and Emacs 32 for canvas | Same as (b), but optional |
| On stock Emacs 31.1 | Works | Works through the JPEG fallback, slower; canvas absent | Works |
| What you gain | Fits Emacs; agents and the rat-kingdom engine share one renderer | Any React or CopilotKit UI, charts, arbitrary HTML | Escape hatch at no cost |
| Effort | Small, incremental | Large: a web app plus a bridge Emacs can't currently drive | None for the basic form |

### Recommendation

Do (a) now; the other two aren't worth building yet. The biggest gaps between
a2ui.el and AG-UI are in the protocol, not in rendering:

1. Build interrupt surfaces from `responseSchema`, as an A2UI form, instead of
   a fixed Approve/Reject. Send `cancelled` on reject.
2. Show AG-UI shared state (STATE_SNAPSHOT/DELTA), for example as a read-only
   tree or table surface.
3. Count interrupts as waiting, in the mode line.
4. Expose `update_a2ui`, `save_a2ui` and `recall_a2ui` as frontend tools.

The basic hybrid (c) is free, so you can try it whenever you like. Revisit
(b) only if both of these hold: an agent you care about produces UI that
A2UI cannot express, and Emacs 32 with canvas has been released and tested on
the NS port.

**The smallest prototype, if wanted.** Without writing code:

1. Install embr and set `browse-url-browser-function` to `embr-browse`.
2. Run `examples/agents/deploy_agent.py` (no API key needed) and have it emit
   an A2UI Button whose action calls `openUrl` with a local page.

This tests the keyboard, theme and latency trade-offs on this Mac with the
JPEG backend before you commit to more. Don't build a page-to-Emacs bridge
until that test shows a real need.

## Question 2: self-hosting CopilotKit Intelligence

### What it is

- **A layer around your app, not an agent host.** "CopilotKit Intelligence
  adds AG-UI Streams, User Memories, Automatic Learning, Channels, and Product
  Analytics to the CopilotKit app you already run." Your agent and model stay
  where they are. Intelligence also offers Trajectories (early access) and an
  Inspector. Its overview page does not mention A2UI.
  ([Intelligence overview](https://docs.copilotkit.ai/intelligence/overview))
  A2UI is a runtime option (`a2ui: {}` on `CopilotRuntime`, which applies
  `A2UIMiddleware`), and the A2UI page says nothing about Intelligence or a
  license. ([CopilotKit A2UI](https://docs.copilotkit.ai/generative-ui/a2ui))
- **AG-UI Streams** records the AG-UI events delivered through CopilotKit, so
  a client can replay a thread and reconnect to an active run.
  "CopilotRuntime runs your agent and sends conversation events to
  CopilotKit Intelligence." ([AG-UI Streams](https://docs.copilotkit.ai/AG-UI-Streams))
- **Self-hosting** uses the `copilot-intelligence` Helm chart. The chart
  deploys `app-api`, `app-frontend`, an optional `realtime-gateway`
  (websocket), a migrations job and a thread-culler CronJob. You need
  Kubernetes ≥ 1.28, Helm ≥ 3.12, an ingress controller, cert-manager,
  PostgreSQL ≥ 14, Redis ≥ 7, and an OIDC identity provider. OpenSearch and
  S3 are optional. A license key (`COPILOTKIT_LICENSE_TOKEN`) is required;
  "contact your CopilotKit account team" if you don't have one.
  ([self-hosting](https://docs.copilotkit.ai/intelligence/self-hosting)) An
  ECS bundle also exists, which I did not read.
- **Local evaluation** runs through `npx copilotkit@latest` (`login`,
  `local setup`, `local connect`), which runs a Docker stack. It is a preview
  for macOS with Docker Desktop and "not a production installation". It needs
  a CopilotKit account (the Developer plan qualifies), comes with a 30-day
  license, and writes `INTELLIGENCE_API_URL`, `INTELLIGENCE_GATEWAY_WS_URL`
  and `CPK_INTELLIGENCE_API_KEY` to your app's `.env`. Data leaves the machine
  for installs and updates, license renewal, the model provider if you
  connect one, and Slack/Teams.
  ([local](https://docs.copilotkit.ai/intelligence/self-hosting-local))
- **License and cost.** The CopilotKit repository is MIT
  ([GitHub](https://github.com/CopilotKit/CopilotKit)); the sources I read
  don't state a license for Intelligence. The pricing page lists:
  - **Free:** "Free for non-production use with a renewable 30-day license."
  - **Pay as you go:** $49/month per organization, hosted or self-hosted.
    Self-hosted needs internet access to report usage.
  - **Annual:** custom terms, including offline.

  ([pricing](https://www.copilotkit.ai/pricing)) The self-hosting page instead
  says self-hosting is on a "Team self-hosted plan or a custom Enterprise
  plan". The two pages disagree, and I can't resolve that from the sources.

### What it would add for Emacs

The key fact is in the runtime's endpoint reference. Without Intelligence,
`POST /api/copilotkit/agent/:agentId/run` takes an AG-UI `RunAgentInput` and
answers with an **SSE stream of AG-UI events**. With Intelligence, run and
connect **return JSON** (`threadId`, `runId`, `joinToken`, `realtime`), and
"the client opens a websocket to `realtime.clientUrl` and joins the
`realtime.topic` channel". A direct POST shows no events.
([runtime endpoints](https://docs.copilotkit.ai/backend/runtime-endpoints))
a2ui.el only speaks POST plus SSE through curl, so it would need a websocket
client and CopilotKit's join protocol, which the docs don't specify further.
It could poll `GET .../threads/:threadId/events` for history, but that's not
live streaming.

What Intelligence offers, and what already covers it:

| Intelligence feature | Covered today by |
|---|---|
| A standard AG-UI endpoint, and routing between agents | a2ui.el already talks to any AG-UI URL in `a2ui-agui-agents`. The MIT runtime alone, without Intelligence, provides `/agent/:agentId/run` (SSE) for several agents. |
| A2UI middleware | It's in the runtime, not Intelligence. a2ui.el already reads its activity events and `forwarded-props` actions. |
| Thread persistence, replay, reconnect | Not covered for AG-UI threads; an a2ui.el thread lives only as long as Emacs. agent-shell/ACP sessions and rat-kingdom's tuplespace persist their own work state, and a2ui.el's saved UIs persist surfaces. |
| User memories, learning, analytics | rat-kingdom's facts (`note_fact`) and the cass memory cover memory for the user's agents; nothing covers product analytics, which a single user doesn't need. |
| Slack/Teams channels | Not relevant to Emacs. |

### Recommendation

**No.** Intelligence is built for teams shipping a CopilotKit web product.
For one user in Emacs, it would mean running Kubernetes, Postgres, Redis and
OIDC, or an evaluation that expires after 30 days. It comes with a licensing
relationship and outbound traffic for usage and license checks. And it would
replace the SSE stream a2ui.el reads with a websocket protocol it doesn't
speak.

**Only if** you want one stable AG-UI URL in front of several agents, run the
open-source CopilotKit runtime *without* Intelligence:

1. Run a small Node service with `CopilotRuntime`, registering each agent as
   an `HttpAgent`, and `a2ui: {}` if the agents return A2UI through the
   middleware.
2. Point an `a2ui-agui-agents` entry at
   `http://127.0.0.1:PORT/api/copilotkit/agent/AGENT/run`, with
   `:action-encoding forwarded-props`.

I haven't tested this against a2ui.el. The runtime may expect fields in
`RunAgentInput` or headers that a2ui.el doesn't send, and the docs flag that
the `threads/*` and `stop` routes need your own authorization. Check it with
`drive-deploy.el` before relying on it.

Reconsider Intelligence only if durable, replayable AG-UI threads become a
real need. Even then, compare it with storing the SSE events a2ui.el already
receives, for example in rat-kingdom's space, which costs no service at all.

## Open risks and unknowns

- **Canvas release and API.** I confirmed the merge to master from the bug
  log, not the final API names, the NEWS entry, the macOS (NS) behaviour, or
  which release ships it. embr's README ("July 2026") and the bug log
  (16 August 2026) disagree about when it landed.
- **embr on macOS.** Only "reported to work". Its default browser,
  CloakBrowser, has closed-source patches. The README documents no API for
  JavaScript or events, though embr.py speaks CDP, so a bridge may be
  possible.
- **Accessibility of embr.** Not documented; assumed absent for pixel output.
- **Intelligence licensing.** The pricing page ($49/month pay as you go,
  free non-production) and the self-hosting page ("Team self-hosted" or
  Enterprise) disagree, and no license for Intelligence is stated.
- **Intelligence's realtime protocol.** Only `clientUrl`, `topic` and
  `joinToken` are documented; I don't know what a non-CopilotKit client would
  have to implement.
- **The runtime without Intelligence as an AG-UI router.** The SSE endpoint
  is documented, but nobody has tested it with a2ui.el's requests or its
  `forwarded-props` action encoding.
- **AG-UI interrupt spec status.** The interrupts page has no draft or
  stable label ([AG-UI interrupts](https://docs.ag-ui.com/concepts/interrupts)),
  so the `responseSchema` work in recommendation (a) could chase a moving
  spec.
