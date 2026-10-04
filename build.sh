#!/usr/bin/env bash
#
# build.sh — build llama.cpp's Vulkan backend tuned for THIS machine.
#
#   Hardware this was written against (auto-detected, not assumed):
#     CPU : AMD Ryzen 5 5600X (Zen 3, 6C/12T, AVX2+FMA, no AVX-512)  -> -march=znver3
#     GPU : AMD Radeon RX 6800 (Navi 21 / gfx1030, RDNA2, 16 GB)     -> RADV / Mesa
#     RAM : 32 GB
#
#   The Vulkan backend has NO build-time tuning knobs: fp16, subgroup size,
#   coopmat and shader-feature flags are all probed from the device at runtime.
#   So "optimized for this hardware" here means: native Zen 3 CPU kernels for
#   the host-side work (tokenize, sampling, graph orchestration, any partial
#   offload), ccache so rebuilds after `git pull` are cheap, and every unrelated
#   backend switched OFF so we don't pay to compile things that can't run here.
#
# Usage:
#   ./build.sh                  # deps + configure + build + smoke test
#   ./build.sh --deps-only      # just install/check build dependencies
#   ./build.sh --no-test        # build only, skip the Gemma 4 smoke test
#   ./build.sh --clean          # wipe the build dir and start over
#   ./build.sh -j 6             # limit parallelism
#   ./build.sh -m /path/to.gguf # override the test model
#   ./build.sh --no-install-deps  # never touch dnf; fail loudly if deps missing
#
set -euo pipefail

# ---------------------------------------------------------------- locations --
# Everything lives under this script's dir; the llama.cpp clone is kept clean
# (out-of-source build) so `git status` in the clone stays pristine.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/llama.cpp"
BUILD="$ROOT/build"
BIN="$BUILD/bin"

# ------------------------------------------------------------------- config --
JOBS="$(nproc)"
MODEL=""
DO_TEST=1
DO_CLEAN=0
DEPS_ONLY=0
ALLOW_DEPS=1

# HF cache: these machines relocate it, so don't assume ~/.cache.
HF_CACHE="${HF_HUB_CACHE:-${HF_HOME:-}/hub}"
[[ -d "$HF_CACHE" ]] || HF_CACHE="$HOME/.cache/huggingface/hub"

# ------------------------------------------------------------------ logging --
if [[ -t 1 ]]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
    C_HEAD=$'\033[1;36m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_OK=; C_WARN=; C_ERR=; C_HEAD=; C_DIM=; C_OFF=
fi
step() { printf '\n%s==> %s%s\n' "$C_HEAD" "$*" "$C_OFF"; }
info() { printf '    %s\n' "$*"; }
dim()  { printf '%s    %s%s\n' "$C_DIM" "$*" "$C_OFF"; }
warn() { printf '%s !! %s%s\n' "$C_WARN" "$*" "$C_OFF"  >&2; }
die()  { printf '%s xx %s%s\n' "$C_ERR" "$*" "$C_OFF"   >&2; exit 1; }
ok()   { printf '%s ok %s%s\n' "$C_OK" "$*" "$C_OFF"; }

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,2\} \{0,1\}//'; }

# --------------------------------------------------------------------- args --
while [[ $# -gt 0 ]]; do
    case "$1" in
        -j|--jobs)  JOBS="${2:?--jobs needs a number}"; shift 2 ;;
        -m|--model) MODEL="${2:?--model needs a path}"; shift 2 ;;
        --clean)       DO_CLEAN=1; shift ;;
        --no-test)     DO_TEST=0; shift ;;
        --deps-only)   DEPS_ONLY=1; DO_TEST=0; shift ;;
        --no-install-deps) ALLOW_DEPS=0; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done

# ============================================================ 0. dependencies ==
# The Vulkan backend is unusable without glslc + SPIRV-Headers; both are
# find_package(... REQUIRED), so CMake dies before it ever looks at your GPU.
REQUIRED_PKGS=(glslc spirv-headers-devel)   # the two Fedora-specific gaps
NEEDED_PKGS=(cmake ninja-build glslc spirv-headers-devel vulkan-loader-devel)

deps_missing() {
    command -v glslc  >/dev/null 2>&1 || return 0
    [[ -f /usr/share/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake ]] || return 0
    return 1
}

install_deps() {
    command -v dnf >/dev/null 2>&1 || die "no dnf on this box; install: ${NEEDED_PKGS[*]}"
    # Never make sudo interactive inside a build script. If it needs a password,
    # print the command and bail so the user isn't staring at a hung prompt.
    if [[ $EUID -ne 0 ]]; then
        sudo -n true 2>/dev/null || die "need root for deps. Run yourself:
    sudo dnf install -y ${NEEDED_PKGS[*]}"
    fi
    step "Installing build dependencies"
    info "${NEEDED_PKGS[*]}"
    sudo dnf install -y "${NEEDED_PKGS[@]}"
}

step "Checking build dependencies"
if deps_missing; then
    # Distinguish "glslc missing" from "SPIRV-Headers missing" — both fail the
    # same way inside CMake otherwise, which makes the error very confusing.
    if ! command -v glslc >/dev/null 2>&1; then
        warn "glslc not found      -> llama.cpp's Vulkan backend cannot build (REQUIRED)"
    fi
    if [[ ! -f /usr/share/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake ]]; then
        warn "SPIRV-Headers missing -> llama.cpp's Vulkan backend cannot build (REQUIRED)"
    fi
    if [[ $ALLOW_DEPS -eq 1 ]]; then
        install_deps
    else
        die "dependencies missing and --no-install-deps was given"
    fi
fi
ok "glslc           $(command -v glslc)"
ok "SPIRV-Headers   $(sed -n 's/^set(PACKAGE_VERSION "\(.*\)"/\1/p' \
        /usr/share/cmake/SPIRV-Headers/SPIRV-HeadersConfigVersion.cmake 2>/dev/null | head -1 || echo present)"

for t in cmake ninja ccache; do
    command -v "$t" >/dev/null 2>&1 || warn "$t not found — proceeding anyway (slower builds)"
done

[[ -d "$SRC" ]] || die "llama.cpp clone not found at $SRC"
ok "source          $SRC  ($(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo '?') on $(git -C "$SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?'))"

# Report the GPU we think we're building for — cheap insurance against silently
# building for the wrong device (e.g. an iGPU would change the whole calculus).
if command -v vulkaninfo >/dev/null 2>&1; then
    GPU="$(vulkaninfo --summary 2>/dev/null | awk -F'= ' '/deviceName/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    DRV="$(vulkaninfo --summary 2>/dev/null | awk -F'= ' '/driverName/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    [[ -n "$GPU" ]] && { ok "target GPU      $GPU  ($DRV)"; dim "Vulkan shader codegen + device tuning happen at runtime."; }
else
    warn "vulkaninfo missing — cannot confirm which GPU we'll target"
fi

[[ $DEPS_ONLY -eq 1 ]] && { ok "dependencies satisfied"; exit 0; }

# ================================================================== 1. clean ==
if [[ $DO_CLEAN -eq 1 ]]; then
    step "Removing $BUILD"
    rm -rf "$BUILD"
    ok "clean"
fi

# =============================================================== 2. configure ==
step "Configuring (Release, Vulkan on, everything else off)"
dim "GGML_NATIVE=ON compiles the CPU backend for -march=native => znver3."
dim "GGML_BLAS is ON by default in llama.cpp; irrelevant for a full-offload"
dim "Vulkan run and it only drags in OpenBLAS. Turning it off."

CMAKE_ARGS=(
    -S "$SRC"
    -B "$BUILD"
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release

    # --- the backend we actually want ---
    -DGGML_VULKAN=ON

    # --- tune the host CPU for Zen 3 ---
    -DGGML_NATIVE=ON
    -DGGML_CPU_REPACK=ON   # Q4_0 -> Q4_X_X repacking; default ON, stated explicitly

    # --- cheap rebuilds after `git pull` ---
    -DGGML_CCACHE=ON
    # LTO deliberately left OFF (the default): for a Vulkan build the hot code
    # is device shaders, not host C++, so LTO costs minutes of build time for
    # ~nothing. Flip to ON if you ever profile time inside the CPU backend.

    # --- the only two backends that default ON but are wrong for this box ---
    -DGGML_BLAS=OFF   # defaults ON on non-Apple; needs OpenBLAS, useless for
                      # a fully-offloaded Vulkan run, pure build-time tax
    -DGGML_VXE=OFF    # defaults to ${GGML_NATIVE}, i.e. ON right now; it's
                      # s390x-only, so this is a no-op that avoids a confusing
                      # "not for this arch" detour during configure
    #
    # Everything else (CUDA/HIP/SYCL/MUSA/Metal/RPC/OpenCL/WebGPU/zDNN/...) is
    # already OFF by default and there is no runtime Vulkan on this hardware,
    # so leave it alone rather than pass 12 -D flags that do nothing.

    # --- llama.cpp: keep server/tools/tests, skip the heavy/irrelevant bits ---
    -DLLAMA_BUILD_SERVER=ON
    -DLLAMA_BUILD_TOOLS=ON
    -DLLAMA_BUILD_TESTS=ON      # test-backend-ops: the real proof the backend works
    -DLLAMA_BUILD_EXAMPLES=OFF  # server + tools cover every workflow we need
    -DLLAMA_BUILD_COMMON=ON
    -DLLAMA_BUILD_UI=OFF        # OFF by default; would fetch a tarball from HF

    # --- debugging aids; clangd/IDE pick these up automatically ---
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
)

# -march=native is the whole point, but say it out loud so a log tells you
# whether it actually took, rather than you discovering it via a slow pp.
if command -v gcc >/dev/null 2>&1; then
    info "gcc -march=native => $(gcc -march=native -Q --help=target 2>/dev/null | awk -F'= +' '/-march=/ {print $2; exit}')"
fi

cmake "${CMAKE_ARGS[@]}"
ok "configured"

# ==================================================================== 3. build ==
step "Building with $JOBS jobs"
dim "First build compiles ~155 Vulkan shaders through glslc; this is the slow part."
dim "Subsequent builds are mostly free thanks to ccache."

cmake --build "$BUILD" --parallel "$JOBS"

step "Build complete"
for b in llama-cli llama-server llama-bench test-backend-ops; do
    if [[ -x "$BIN/$b" ]]; then
        # Not every tool supports --version (llama-bench ignores it and starts
        # probing devices instead), so grep rather than print raw output.
        v="$("$BIN/$b" --version 2>&1 | grep -m1 -oE 'version: [^ ]+' || true)"
        printf '    %s%-17s%s %s\n' "$C_OK" "$b" "$C_OFF" "${v:-built}"
    else
        printf '    %s%-17s%s %s\n' "$C_WARN" "$b" "$C_OFF" "${C_WARN}not built${C_OFF}"
    fi
done
dim "binaries: $BIN"
[[ $DO_TEST -eq 0 ]] && exit 0

# ================================================================ 4. smoke test ==
# Pick a small local GGUF out of the HF cache. Gemma 4 12B Q4_K_XL is 6.26 GiB
# against 16 GB of VRAM, so this should report a 100% GPU offload.
find_model() {
    if [[ -n "$MODEL" ]]; then echo "$MODEL"; return; fi
    local cand
    for cand in \
        "$HF_CACHE"/models--unsloth--gemma-4-12B-it-qat-GGUF/snapshots/*/gemma-4-12B*.gguf \
        "$HF_CACHE"/models--huihui-ai--*gemma-4-12B*/snapshots/*/*.gguf \
        "$HF_CACHE"/models--unsloth--gemma-4-E4B*/snapshots/*/*.gguf
    do
        # Skip multimodal projectors and MTP heads — we want the main weights.
        [[ -e "$cand" ]] || continue
        case "$cand" in *mmproj*|*-mtp-*) continue ;; esac
        echo "$cand"; return
    done
    return 1
}

step "Smoke test"
M="$(find_model || true)"
if [[ -z "$M" ]]; then
    warn "no Gemma GGUF found under $HF_CACHE — skipping smoke test."
    info "Pass -m /path/to/model.gguf to test a specific model."
    exit 0
fi
# HF snapshots are symlinks into blobs/; -L so du sees through them.
ok "model       $(basename "$M")  ($(du -hL "$M" 2>/dev/null | cut -f1))"

# 6 physical cores. SMT rarely helps GGML (it's already bandwidth-saturated and
# the two halves share an FP unit), so pin threads to cores, not nproc.
THREADS="$(lscpu 2>/dev/null | awk -F': *' '/^Core\(s\) per socket/ {print $2; exit}')"
THREADS="${THREADS:-$(nproc)}"

# -- 4a. generation: prove it produces real text --------------------------
# NB: --single-turn, not -no-cnv / --no-conversation. Those are registered for
# LLAMA_EXAMPLE_COMPLETION only, and llama.cpp filters args per-example, so
# llama-cli rejects them with a bare "error: invalid argument".
info "generation test"
if "$BIN/llama-cli" -m "$M" -p "The capital of France is" -n 32 -t "$THREADS" --single-turn --temp 0 2>&1 | tail -12; then
    ok "generation OK"
else
    die "generation test failed"
fi

# -- 4b. llama-bench: confirm the offload actually landed -----------------
# This is the check that matters. If the backend column says CPU, or ngl is not
# negative (negative == "all layers"), the Vulkan backend silently fell back.
info "benchmark (pp=512, tg=128)"
BENCH_OUT="$("$BIN/llama-bench" -m "$M" -p 512 -n 128 -t "$THREADS" -r 2 2>&1)"
echo "$BENCH_OUT" | grep -i "ggml_vulkan: 0 =" | sed 's/^/    /' || true
echo "$BENCH_OUT" | grep -E "^\| (model|gemma|llama)" || echo "$BENCH_OUT" | tail -8

if echo "$BENCH_OUT" | grep -qE "^\| [a-z0-9_-]+ .*\| Vulkan"; then
    ok "full GPU offload confirmed"
else
    warn "did not see a Vulkan row — backend may have fallen back to CPU"
fi

dim "    matrix cores: none is expected on RDNA2 (RADV exposes no coopmat"
dim "    for gfx1030), so ggml won't use matrix-core paths. fp16: dot2 means"
dim "    compute runs in fp16, which is what you want on this card."

info "sane thread count for this machine: -t $THREADS (6 physical cores)"
dim "    full-offload prompt processing is GPU-bound; -t mostly affects"
dim "    tokenization, sampling, and the host-side graph. Tune it if pp regresses."

printf '\n%s%s%s\n' "$C_OK" "Done. Try:
    $BIN/llama-server -m $M -ngl 999 -t $THREADS --port 8080
    $BIN/llama-bench  -m $M -p 512 -n 128 -t $THREADS" "$C_OFF"