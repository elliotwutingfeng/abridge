#!/usr/bin/env bash
##
## Cloudflare Workers & Pages build commands (Build system Version 3):
## ./build-zola.sh npm run abridge -- --base-url https://abridge.pages.dev
## ./build-zola.sh npm run abridge -- --mode tinysearch --base-url https://abridge-tinysearch.pages.dev
## ./build-zola.sh npm run abridge -- --mode pagefind --base-url https://abridge-pagefind.pages.dev
##

set -euo pipefail

# Resolve files belonging to Abridge relative to this script, not the caller's
# working directory. This allows the helper to work both from the Abridge repo
# root and when Abridge is installed as themes/abridge in another Zola site.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
THEME_TOML="$SCRIPT_DIR/theme.toml"

if [[ ! -f "$THEME_TOML" ]]; then
    echo "ERROR: Abridge theme.toml was not found at $THEME_TOML" >&2
    exit 1
fi

ZOLA_VERSION="$(
    sed -nE 's/^[[:space:]]*min_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$THEME_TOML" \
        | head -n 1
)"

if [[ -z "$ZOLA_VERSION" ]]; then
    echo "ERROR: min_version was not found in $THEME_TOML" >&2
    exit 1
fi

# Pinned maintainer/build dependencies for Tinysearch mode.
TINYSEARCH_VERSION="0.11.1"
TINYSEARCH_SHA256="d91c5470afc2d05bf72f3259ffdc178ca19f96ce30847717a1cc64b2d0a6640c"
BINARYEN_VERSION="132"
BINARYEN_NODE_SHA256="f2f49e583f5eafbe2af5da8470177d4d10aedf149752f5dd97736f54eba6f6a2"

needs_tinysearch=false
for arg in "$@"; do
    if [[ "$arg" == "tinysearch" || "$arg" == "--mode=tinysearch" ]]; then
        needs_tinysearch=true
        break
    fi
done

echo "Using Zola ${ZOLA_VERSION} from theme.toml"

TOOLS_DIR="$(mktemp -d)"
trap 'rm -rf "$TOOLS_DIR"' EXIT

curl -fsSL \
    "https://github.com/getzola/zola/releases/download/v${ZOLA_VERSION}/zola-v${ZOLA_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
    | tar -xz -C "$TOOLS_DIR"

if [[ "$needs_tinysearch" == true ]]; then
    echo "Using Tinysearch ${TINYSEARCH_VERSION} for Tinysearch mode"

    TINYSEARCH_ARCHIVE="$TOOLS_DIR/tinysearch.tar.gz"
    TINYSEARCH_EXTRACT_DIR="$TOOLS_DIR/tinysearch-release"

    mkdir -p "$TINYSEARCH_EXTRACT_DIR"

    curl -fsSL \
        "https://github.com/tinysearch/tinysearch/releases/download/v${TINYSEARCH_VERSION}/tinysearch-v${TINYSEARCH_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        -o "$TINYSEARCH_ARCHIVE"

    echo "${TINYSEARCH_SHA256}  ${TINYSEARCH_ARCHIVE}" | sha256sum -c -

    tar -xzf "$TINYSEARCH_ARCHIVE" -C "$TINYSEARCH_EXTRACT_DIR"

    TINYSEARCH_BIN="$(find "$TINYSEARCH_EXTRACT_DIR" -type f -name tinysearch -perm -u+x -print -quit)"

    if [[ -z "$TINYSEARCH_BIN" ]]; then
        echo "ERROR: tinysearch executable was not found after extraction." >&2
        exit 1
    fi

    ln -sf "$TINYSEARCH_BIN" "$TOOLS_DIR/tinysearch"

    echo "Using Binaryen ${BINARYEN_VERSION} wasm-opt for Tinysearch optimization"

    BINARYEN_ARCHIVE="$TOOLS_DIR/binaryen-node.tar.gz"

    curl -fsSL \
        "https://github.com/WebAssembly/binaryen/releases/download/version_${BINARYEN_VERSION}/binaryen-version_${BINARYEN_VERSION}-node.tar.gz" \
        -o "$BINARYEN_ARCHIVE"

    echo "${BINARYEN_NODE_SHA256}  ${BINARYEN_ARCHIVE}" | sha256sum -c -

    tar -xzf "$BINARYEN_ARCHIVE" -C "$TOOLS_DIR"

    WASM_OPT_JS="$TOOLS_DIR/binaryen-version_${BINARYEN_VERSION}/wasm-opt.js"

    if [[ ! -f "$WASM_OPT_JS" ]]; then
        echo "ERROR: Binaryen wasm-opt.js was not found after extraction." >&2
        exit 1
    fi

    cat > "$TOOLS_DIR/wasm-opt" <<EOF
#!/usr/bin/env bash
exec node "$WASM_OPT_JS" "\$@"
EOF

    chmod +x "$TOOLS_DIR/wasm-opt"
fi

export PATH="$TOOLS_DIR:$PATH"

zola --version

if [[ "$needs_tinysearch" == true ]]; then
    echo "glibc:"
    ldd --version | head -n1 || true

    echo "rustc:"
    rustc --version || true

    echo "cargo:"
    cargo --version || true

    echo "rustup:"
    rustup --version || true

    echo "wasm target:"
    rustup target list --installed 2>/dev/null || true

    tinysearch --version
    wasm-opt --version >/dev/null
fi

exec "$@"
