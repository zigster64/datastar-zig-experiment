# zig2

Rewrite to use datastar.zig - try to get the DX inline with the Go code at least
A small example web server in **Zig 0.16** that renders a table of users as
HTML, backed by **SQLite**, with add/delete driven by
[**Datastar**](https://data-star.dev). The database is created and seeded with
sample data on first run.

```
               commands (writes)
┌─────────────┐  POST /users/ · DELETE /users/1   ┌──────────────────┐   ┌───────────┐
│             │ ────────────────────────────────> │                  │   │           │
│ browser     │                                   │ std.http.Server  │──>│ SQLite DB │
│ + Datastar  │        read model (SSE)           │  (src/server.zig)│   │ users.db  │
│             │ <═══ GET /updates  (data-init) ══ │  + broadcast Hub │   │           │
└─────────────┘   fat morphs of #content          └──────────────────┘   └───────────┘
```

The design is **CQRS-flavored** — reads and writes travel on separate paths:

- On load, the page opens a long-lived **Server-Sent-Events** stream to
  `GET /updates` via Datastar's [`data-init`](https://data-star.dev/reference/attributes#data-init).
  That stream is the source of truth for the view: on connect, and after every
  change, it pushes a **"fat morph"** — the entire `#content` region re-rendered
  — which Datastar morphs into the DOM in place.
- **Commands** (`POST /users/`, `DELETE /users/{id}`) only *mutate* the database
  and then `publish()` to an in-process **`Hub`**. Every open `/updates` stream
  notices the new version and re-renders, so **all connected clients update at
  once** — the command response itself never carries the table.

The "Add user" and per-row "Delete" buttons open native `<dialog>` elements
**client-side** (no round-trip to open them). The create command validates the
submitted fields; on a problem it re-renders **just the dialog** (targeted by
`id`) with an inline error, keeping the entered values.

## Requirements

- **Zig 0.16.0** (uses the reorganized `std.Io` networking/reader/writer APIs and
  the `std.process.Init` entry point).
- A C toolchain — the build compiles the **vendored SQLite amalgamation** in
  [`vendor/sqlite/`](vendor/sqlite/), so no system SQLite is required.
- No network access at build time beyond the one-time `zig fetch` of the
  Datastar SDK (already pinned in `build.zig.zon`).

## Dependencies

- **[SQLite](https://sqlite.org)** — vendored amalgamation in `vendor/sqlite/`,
  compiled by `build.zig`.
- **[Datastar](https://data-star.dev) v1.0.2** — the browser runtime is vendored
  in `vendor/datastar/` and served at `/datastar.js` (embedded in the binary).
- **[datastar-zig](https://github.com/starfederation/datastar-zig)** — the
  server-side SDK (a `build.zig.zon` package dependency) that parses Datastar
  request signals and formats the SSE patch responses.

## Run

```sh
zig build run
# then open http://127.0.0.1:8080/
```

Optional arguments — listen address and database path:

```sh
zig build run -- 0.0.0.0:9000 /tmp/users.db
# or run the built binary directly:
./zig-out/bin/zigvibe 127.0.0.1:8080 users.db
```

Routes:

| Method    | Path                          | Response                                            |
|-----------|-------------------------------|-----------------------------------------------------|
| GET, HEAD | `/`, `/users`, `/index.html`  | `200` HTML page shell (boots the `/updates` stream) |
| GET       | `/updates`                    | `200` **SSE stream** — fat morphs of `#content`     |
| GET       | `/datastar.js`                | `200` the vendored Datastar runtime                 |
| POST      | `/users/`                     | create a user; publishes → stream refreshes         |
| DELETE    | `/users/{id}`                 | delete a user; publishes → stream refreshes         |
| GET       | anything else                 | `404` text                                          |
| other     | any                           | `405` text                                          |

`POST /users/` reads the submitted fields from Datastar signals (a JSON body)
and validates each independently: a blank name, a blank/invalid email (checked
against `^[^@\s]+@[^@\s]+\.[^@\s]+$`), or a duplicate email is rejected by
re-rendering the `#add-dialog` (a targeted element patch) with each field's
error shown **directly beneath that field's input** — the table is left
untouched. On success the row is inserted, the change is published, and
the dialog is cleared and closed.

## Develop

The HTML lives in [zt](https://github.com/lalinsky/zt) templates
([`src/templates/users.zt`](src/templates/users.zt)) — a Templ-style language
that compiles to Zig at build time. zt is vendored and patched for Zig 0.16 in
[`vendor/zt/`](vendor/zt/) (see [`vendor/zt/PATCH.md`](vendor/zt/PATCH.md)); the
`.zt` → `.zig` transpile runs automatically as part of every `zig build`, and
the generated `src/templates/users.zig` is committed.

Edit sources, rerun `zig build run`, and reload the browser.

## Test

```sh
zig build test
```

Unit tests cover the SQLite wrapper, the data layer (schema + idempotent
seeding, insert, delete), the email validator, HTML rendering (including
escaping), the `Hub`, the SSE content event, and the HTTP request routing —
including create validation (empty/invalid/duplicate) and delete — all driven
over in-memory streams, so no socket is needed. The end-to-end SSE broadcast and
dialog behavior are verified separately in a real browser.

## Why HTTP/1.1 and not HTTP/2?

HTTP/2's benefits — multiplexing, header compression, single-connection reuse —
are almost entirely a *client ↔ edge* concern. In a typical deployment you
terminate HTTP/2 (and TLS) at a load balancer / reverse proxy / CDN and speak
plain HTTP/1.1 to the application server over the fast internal hop, where those
benefits don't apply. Backend HTTP/2 mainly earns its place for gRPC or
end-to-end streaming.

Zig's standard library implements HTTP/1.1 only (`std.http`); there is no
HTTP/2 in std, and third-party Zig HTTP/2 libraries are immature and tend to lag
new Zig releases. So this example uses the idiomatic, dependency-free
`std.http.Server` — which is also the realistic shape of a Zig app server
sitting behind a proxy.

## Layout

| File                 | Responsibility                                             |
|----------------------|------------------------------------------------------------|
| `src/main.zig`       | Entry point: parse args, open/seed DB, start the server    |
| `src/server.zig`     | Accept loop, routing, `Hub`, `/updates` SSE, command validation |
| `src/db.zig`         | `users` schema, first-run seeding, queries, insert, delete |
| `src/sqlite.zig`     | Wrapper over the SQLite C API                              |
| `src/templates/users.zt` | The page + fragments as [zt](https://github.com/lalinsky/zt) templates (source of truth for the HTML) |
| `src/html.zig`       | Adapter over the generated templates (keeps the `render*` API) |
| `vendor/zt/`         | Vendored zt transpiler, patched for Zig 0.16 (see `PATCH.md`) |
| `vendor/sqlite/`     | Vendored SQLite amalgamation (compiled by `build.zig`)     |
| `vendor/datastar/`   | Vendored Datastar browser runtime (served at `/datastar.js`)|

## Design notes

- **Read/write separation (CQRS).** The `/updates` SSE stream is the only thing
  that renders the table; commands just mutate and `publish()`. This keeps
  command handlers tiny, makes every client converge on the same state, and
  means "what the page looks like" lives in exactly one place.
- **Fat morphs.** The stream re-renders the whole `#content` region and lets
  Datastar's morph compute the minimal DOM change, rather than emitting
  fine-grained per-row add/remove patches. Simpler server code, and the toolbar
  and dialogs (which hold client-only state like the theme indicator) sit
  outside `#content` so a morph never clobbers them.
- **The broadcast Hub** is a lock-free monotonic version counter. Each stream
  remembers the version it last rendered and polls between short sleeps
  (`std.Io.sleep`); polling doubles as a heartbeat that detects dropped clients.
  A production build would swap this for an event/condition to avoid idle wakeups.
- **Threading.** A fixed pool of worker threads (bounded, reused) serves
  connections; the kernel load-balances `accept` across them. Each worker owns
  one SQLite connection and one request arena for its lifetime — no per-request
  thread or arena creation. A long-lived `/updates` stream occupies its worker,
  so the pool size bounds concurrent clients.
- **SQLite.** Each worker's connection is opened `SQLITE_OPEN_NOMUTEX`
  (multi-thread mode — no per-call mutex, safe because a connection is never
  shared), in WAL with `synchronous = NORMAL` (concurrent readers, one writer),
  with a 5s busy timeout. Prepared statements are compiled once and reused per
  connection (`prepareCached`).
- **Escaping.** All user-derived values are HTML-escaped in `src/html.zig`, so
  data in the database can never inject markup — including the values embedded
  in Datastar `data-*` attributes on each delete button.
- **Seeding is idempotent.** `db.init` creates the schema and only inserts the
  sample rows when the table is empty, so restarts don't duplicate data.
- **Client- vs server-side dialogs.** Opening/closing dialogs and copying a
  row's id into a signal are pure client-side Datastar expressions. The server
  only re-renders the add dialog when it has a validation error to report.
- **Light/dark theming.** Colors are declared once with the CSS `light-dark()`
  function under `color-scheme: light dark`, so the page follows the OS setting
  with no JavaScript. A small `matchMedia('(prefers-color-scheme: dark)')`
  listener additionally reacts to *runtime* changes: it mirrors the mode onto
  `<html data-theme>` (an override hook), updates the on-page indicator, and
  fires a `themechange` event — no reload required.
