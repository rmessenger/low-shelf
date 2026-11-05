#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun clang -std=c11 -Wall -Wextra -Werror -fsyntax-only -I Sources/BassDSP/include Sources/BassDSP/BassDSP.c
swift run -c release -Xswiftc -warnings-as-errors DSPChecks
swift run -c release -Xswiftc -warnings-as-errors HotKeyChecks
swift build -c release --product LowShelf -Xswiftc -warnings-as-errors
