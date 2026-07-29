#!/usr/bin/env bash
# Runs the pure-logic tests against the REAL shared modules, with no Studio and
# no Rojo connection involved.
#
# src/shared uses Roblox-style requires (`require(script.Parent.X)`) and a few
# Roblox globals, neither of which the standalone Luau CLI knows about. So the
# modules are copied to a temp dir, their requires rewritten to path requires,
# and spec.luau stubs the handful of Roblox types they touch.
#
# Only genuinely pure modules can be tested this way -- anything reaching for
# Players, Workspace or remotes belongs in a Studio session instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LUAU="${LUAU:-$HOME/.rokit/bin/luau}"

if [[ ! -x "$LUAU" ]]; then
	echo "luau not found at $LUAU -- install with: rokit add luau-lang/luau" >&2
	exit 1
fi

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

cp "$ROOT"/src/shared/*.luau "$BUILD"/
cp "$ROOT"/tests/spec.luau "$BUILD"/

# require(script.Parent.Foo) / require(Shared.Foo) -> require("./Foo")
for file in "$BUILD"/*.luau; do
	perl -pi -e 's/require\((?:script\.Parent|Shared)\.(\w+)\)/require(".\/$1")/g' "$file"
done

# Roblox datatypes used by the modules under test. Injected as a file-local in
# each file that mentions one, rather than as a global -- _G is readonly in the
# Luau CLI sandbox. Nothing under test reads the values back, so these only need
# to construct without erroring.
STUB='local Color3 = { fromRGB = function(r, g, b) return { R = r, G = g, B = b } end }'
for file in "$BUILD"/*.luau; do
	if grep -q 'Color3' "$file"; then
		printf '%s\n%s\n' "$STUB" "$(cat "$file")" > "$file.tmp" && mv "$file.tmp" "$file"
	fi
done

# Run from the project root, not the build dir: the rokit shim resolves `luau`
# via the nearest rokit.toml, and there isn't one in a temp directory. Luau
# resolves `./` requires relative to the requiring FILE, so the spec still finds
# its modules from wherever it's invoked.
cd "$ROOT"
"$LUAU" "$BUILD/spec.luau"
