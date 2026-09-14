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

RUSTUP_VERSION="1.29.0"
RUSTUP_SHA256="4acc9acc76d5079515b46346a485974457b5a79893cfb01112423c89aeb5aa10"
RUST_VERSION="1.98.1"
RUST_HOST="x86_64-unknown-linux-gnu"
RUST_WASM_TARGET="wasm32-unknown-unknown"

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
    #
    # Tinysearch
    #
    echo "Using Tinysearch ${TINYSEARCH_VERSION} for Tinysearch mode"

    TINYSEARCH_ARCHIVE="$TOOLS_DIR/tinysearch.tar.gz"
    TINYSEARCH_EXTRACT_DIR="$TOOLS_DIR/tinysearch-release"

    mkdir -p "$TINYSEARCH_EXTRACT_DIR"

    curl -fsSL \
        "https://github.com/tinysearch/tinysearch/releases/download/v${TINYSEARCH_VERSION}/tinysearch-v${TINYSEARCH_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        -o "$TINYSEARCH_ARCHIVE"

    echo "${TINYSEARCH_SHA256}  ${TINYSEARCH_ARCHIVE}" | sha256sum -c -

    tar -xzf "$TINYSEARCH_ARCHIVE" -C "$TINYSEARCH_EXTRACT_DIR"

    TINYSEARCH_BIN="$(
        find "$TINYSEARCH_EXTRACT_DIR" \
            -type f \
            -name tinysearch \
            -perm -u+x \
            -print \
            -quit
    )"

    if [[ -z "$TINYSEARCH_BIN" ]]; then
        echo "ERROR: tinysearch executable was not found after extraction." >&2
        exit 1
    fi

    ln -sf "$TINYSEARCH_BIN" "$TOOLS_DIR/tinysearch"

    #
    # Rust/Cargo
    #
    # Tinysearch generates a temporary Rust crate and uses Cargo to compile
    # the search implementation for wasm32-unknown-unknown.
    #
    echo "Using Rust ${RUST_VERSION} for Tinysearch WebAssembly compilation"

    RUSTUP_INIT="$TOOLS_DIR/rustup-init"

    curl -fsSL \
        "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${RUST_HOST}/rustup-init" \
        -o "$RUSTUP_INIT"

    echo "${RUSTUP_SHA256}  ${RUSTUP_INIT}" | sha256sum -c -

    chmod +x "$RUSTUP_INIT"

    export RUSTUP_HOME="$TOOLS_DIR/rustup"
    export CARGO_HOME="$TOOLS_DIR/cargo"

    "$RUSTUP_INIT" \
        -y \
        --no-modify-path \
        --profile minimal \
        --default-host "$RUST_HOST" \
        --default-toolchain "$RUST_VERSION"

    "$CARGO_HOME/bin/rustup" \
        target add "$RUST_WASM_TARGET" \
        --toolchain "$RUST_VERSION"

    #
    # Binaryen / wasm-opt
    #
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

if [[ "$needs_tinysearch" == true ]]; then
    export PATH="$TOOLS_DIR:$CARGO_HOME/bin:$PATH"
else
    export PATH="$TOOLS_DIR:$PATH"
fi

zola --version

if [[ "$needs_tinysearch" == true ]]; then
    tinysearch --version
    rustc --version
    cargo --version
    wasm-opt --version >/dev/null
fi

exec "$@"
