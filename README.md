# sketchup_MCP

Let Claude Code (or any MCP client) drive a **live SketchUp session**: run Ruby
against the SketchUp API, read the selection/geometry, and take viewport
screenshots.

```
Claude Code ──stdio──► mcp/server.rb ──TCP 127.0.0.1 + token──► SketchUp: MCP Bridge window
```

## Why the bridge has a window

The SketchUp API may only be used on the main thread, and Ruby threads inside
SketchUp starve while the app is idle. So the bridge uses **no threads**: the
"MCP Bridge" window runs a 50 ms JavaScript interval that calls Ruby, and each
tick accepts/reads/answers with non-blocking sockets on the main thread.
**Keep the window open while Claude works**; closing it stops the bridge.

## Install

1. **SketchUp side.** Either copy `bridge/sketchup_mcp_bridge.rb` and the
   `bridge/sketchup_mcp_bridge/` folder into your Plugins folder, or (dev) add
   a one-line stub to the Plugins folder so edits in this repo apply directly:

   ```ruby
   # %APPDATA%/SketchUp/SketchUp 2023/SketchUp/Plugins/sketchup_mcp_bridge.rb
   load "C:/Users/<you>/projects/sketchup_mcp/bridge/sketchup_mcp_bridge.rb"
   ```

   Restart SketchUp, then open **Extensions › MCP Bridge**.

2. **Claude Code side** (needs any Ruby ≥ 2.7, no gems):

   ```sh
   claude mcp add --scope user sketchup -- ruby C:/Users/<you>/projects/sketchup_mcp/mcp/server.rb
   ```

When the window opens it writes `%APPDATA%/sketchup_mcp/bridge.json`
(port + a fresh random token); the MCP server reads it on every call, so
restarting SketchUp needs no MCP restart. Set `SKETCHUP_MCP_HOME` to move it.

## Tools

| Tool | What it does |
|---|---|
| `sketchup_status` | SketchUp/Ruby version, model title/path, units, selection count |
| `eval_ruby` | Run Ruby in SketchUp. **One call = one undo step** (aborted on error). Locals persist between calls; `puts` output is returned. |
| `get_selection` | Selected entities: class, entityID, name/definition, tag, bounds (mm) |
| `list_entities` | Entities in the active drawing context |
| `dump_entity` | Faces (outer loop, normal, area), edges, nested instances of one group/component, in mm |
| `screenshot` | Viewport PNG returned as an image |
| `undo` | Ctrl+Z |

## Security

The bridge executes arbitrary Ruby. It listens on `127.0.0.1` only, and every
request must carry the per-session token from `bridge.json`. It is a developer
tool — do not ship it inside an end-user extension.

## Tests

```sh
ruby test/run_all.rb
```

Everything except `handlers.rb` (the SketchUp API calls) is covered without
SketchUp, including an end-to-end test that runs the real MCP process over
stdio against the real bridge server.
