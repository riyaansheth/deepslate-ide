#!/bin/zsh
# Compiles the non-UI sources with the self-check (Tests/main.swift) and runs it.
set -e
cd "${0:a:h}/.."
OUT=$(mktemp -d)/selftest
swiftc -swift-version 5 -o "$OUT" Sources/Deepslate/{Providers,Agent,Handoff}.swift Tests/main.swift
"$OUT"
