# Deepslate

A native macOS coding agent for when your Claude or ChatGPT plan hits its limit: paste an API key and keep going.
It can also pick up where a Claude Code or Codex session left off.

- Build: `./build.sh 1.0.0` → `dist/Deepslate.app` + `dist/Deepslate-1.0.0.dmg` (needs only Xcode Command Line Tools)
- Self-check: `./Tests/run.sh`
- Release: `gh release create v1.0.0 dist/Deepslate-1.0.0.dmg --repo riyaansheth/deepslate-ide`

The DMG is ad-hoc signed, not notarized. On first launch, right-click the app and choose Open.

MIT licensed.
