# DesignParity

**Does the screen you built match the design?** DesignParity compares a running iOS Simulator screen (or any screenshot) with its Figma frame and tells you exactly what differs, in points: missing or changed text, elements that moved or changed size, and every area that looks different.

It is built for the loop AI coding agents run: *implement a screen → check it against the design → fix → check again*. Use it as an **MCP server** in Claude Code, Cursor or any MCP client, as a **CLI**, or as a **CI gate**.

[![CI](https://github.com/Ali-Asadi-Dev/DesignParity/actions/workflows/ci.yml/badge.svg)](https://github.com/Ali-Asadi-Dev/DesignParity/actions/workflows/ci.yml)

## What it reports

The [example](Examples) is a real app screen with three planted mistakes: a label removed, a section shifted down, an icon recolored. CI runs `parity compare` on it on macOS; this is its output:

```
## ❌ Differs from the design: 11 areas — 98.36% of pixels match

### Text
- **Missing** “6 active subscriptions” at (38, 297) pt.
- **Moved together** (9 texts from y 492 pt): 12 pt too low. “Next 7 days”, “Netflix”, “$15.49” and 6 more.

### Areas that differ (top to bottom)
1. x 39–165, y 297–312 pt (126×15 pt)      ← the missing label
2. x 39–81, y 405–447 pt (42×42 pt)        ← the recolored icon
3. x 39–132, y 492–522 pt (93×30 pt)       ← the shifted section starts here
…
```

All three are found, and the report says where and by how much, in points. Note the 98.36%: a screen can match almost every pixel and still be wrong, so DesignParity fails on any real difference, not on a percentage.

It also writes `overlay.png` (the screenshot faded, differences in red, areas outlined), `report.json` for tools, and `report.md`. The latest output from CI is on the [`example-output`](https://github.com/Ali-Asadi-Dev/DesignParity/tree/example-output) branch.

## How it works

1. **Align.** The screenshot is scaled to the design's width (Figma exports at 3x; simulators differ by device). Status bar and home indicator can be ignored.
2. **Compare pixels perceptually.** Colors are compared in the YIQ color space, the way people perceive differences, and anti-aliased edges are ignored, so font smoothing differences between Figma and iOS don't count (a Swift port of [pixelmatch](https://github.com/mapbox/pixelmatch)'s algorithm).
3. **Group into areas.** Differing pixels are clustered in point units, so one changed element is one area, and tiny rendering noise is dropped.
4. **Compare text.** Figma's text layers (or on-device OCR of a design PNG) are matched against OCR of the screen with Apple's Vision framework, on device and offline. It tolerates OCR joining or splitting lines, then reports text that is missing, different, moved or resized.

## Install

Requires macOS 13+ and Xcode (for the Simulator).

```bash
git clone https://github.com/Ali-Asadi-Dev/DesignParity && cd DesignParity
swift build -c release
cp .build/release/parity /usr/local/bin/
```

To compare with Figma links, create a personal access token (Figma → Settings → Security → Personal access tokens, read-only file access) and set `FIGMA_TOKEN`.

Optional settings:

| Variable | Default | |
|---|---|---|
| `PARITY_OCR_LANGUAGES` | `en-US` | Comma-separated languages for text recognition, e.g. `de-DE,en-US`. Vision supports many languages but not all (Persian is not supported, so on Persian screens only pixels and layout are compared). |
| `PARITY_OCR_CPU_ONLY` | off | Set to `1` on machines without a Neural Engine, such as CI virtual machines. |

## Use with an AI coding agent (MCP)

```bash
claude mcp add parity --env FIGMA_TOKEN=your-token -- parity mcp
```

Other clients: run `parity mcp` as a stdio MCP server. Tools:

| Tool | What it does |
|---|---|
| `check_design` | Compare the booted simulator (or a screenshot) with a Figma link or design PNG. Returns the report and the overlay image. |
| `capture_simulator` | Screenshot of the booted simulator. |

Then ask your agent something like *"Implement this screen: <Figma link>. Run it in the simulator and use check_design until it passes."*

## Use from the command line

```bash
# The running simulator vs a Figma frame
parity compare "https://www.figma.com/design/<file>/<name>?node-id=12-34" simulator --ignore-top 59

# Two PNGs, e.g. in CI (exit status 1 when they differ)
parity compare design.png screenshot.png --width-points 393 --ignore-top 59 --output parity-report

parity capture -o screen.png       # screenshot the booted simulator
parity figma "<frame link>"        # download a frame PNG and its text layers
```

## Project layout

| Module | |
|---|---|
| `ParityCore` | Pixel diff, region grouping, text matching, report and overlay. Pure Swift: builds and is tested on Linux too. |
| `ParityFigma` | Figma REST client: frame PNG and text layers (the token is never sent to the image CDN). |
| `ParityApple` | macOS adapters: PNG via ImageIO, text recognition via Vision, the Simulator via `simctl`. |
| `ParityMCP` | A small, dependency-free Model Context Protocol server (JSON-RPC over stdio). |
| `parity` | The CLI (swift-argument-parser). |

Tests: 39 on Linux, plus macOS tests that run real Vision text recognition on the example and check that all three planted mistakes are found.

## License

MIT
