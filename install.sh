#!/bin/bash
# install.sh — crossbow installer / doctor / self-healer
#   Installs & verifies the crossbow toolchain: go · katana · dalfox · arjun · python3
#   Designed for a fresh Kali (rolling). Never runs `apt update`/`apt upgrade`
#   (that breaks the rolling toolset) — tools come from Go, pipx and the
#   official Go tarball instead.
#
#   Usage:
#     ./install.sh                # user-local install (tools in ~/go/bin, ~/.local/bin)
#     ./install.sh --system       # system-wide: tools in /usr/local/bin for root + all users
#     ./install.sh -y             # assume "yes" to every prompt (incl. upgrades)
#     ./install.sh --upgrade      # force-upgrade everything to latest
#     ./install.sh --no-upgrade   # only install/heal, never offer upgrades
#     ./install.sh --force        # reinstall every tool from scratch
#     ./install.sh --check        # diagnose only — install/change nothing
#     ./install.sh -h
#
#   Run as your normal user (NOT `sudo ./install.sh`). The script self-elevates
#   with sudo only where root is required; --system places tool binaries in
#   /usr/local/bin so `sudo crossbow` works too.
#
set -uo pipefail

# ── Minimum versions ───────────────────────────────────────────
GO_MIN="1.21.0"      # building recent katana/dalfox needs a modern toolchain
KATANA_MIN="1.0.5"
DALFOX_MIN="2.9.0"
ARJUN_MIN="2.2.0"
PY_MIN="3.8.0"

# Pinned fallback if go.dev is unreachable when fetching the latest tarball
GO_FALLBACK="go1.22.5"

# ── Colors & logging (match crossbow.sh style) ─────────────────
setup_colors() {
    if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
        RED='\033[0;31m'    GREEN='\033[0;32m'
        YELLOW='\033[0;33m' BLUE='\033[0;34m'
        CYAN='\033[0;36m'   BOLD='\033[1m'
        DIM='\033[2m'       RESET='\033[0m'
    else
        RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' RESET=''
    fi
}
log_info() { echo -e "${BLUE}[*]${RESET} $*" >&2; }
log_ok()   { echo -e "${GREEN}[+]${RESET} $*" >&2; }
log_warn() { echo -e "${YELLOW}[!]${RESET} $*" >&2; }
log_err()  { echo -e "${RED}[-]${RESET} $*" >&2; }
log_step() { echo -e "\n${BOLD}${CYAN}>>> $*${RESET}" >&2; }

banner() {
    echo -e "${DIM}   \\\\     //${RESET}"
    echo -e "${DIM}    \\\\${BOLD}═══${DIM}//${RESET}"
    echo -e "${BOLD} ════╬═●═╬════►${RESET}  ${CYAN}crossbow installer${RESET}"
    echo -e "${DIM}    //${BOLD}═══${DIM}\\\\${RESET}"
    echo -e "${DIM}   //     \\\\${RESET}     ${DIM}go · katana · dalfox · arjun${RESET}"
    echo ""
}

# ── Flags ──────────────────────────────────────────────────────
ASSUME_YES=0  FORCE=0  NO_UPGRADE=0  WANT_UPGRADE=0  CHECK_ONLY=0  SYSTEM=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)      ASSUME_YES=1; shift ;;
        --upgrade)     WANT_UPGRADE=1; shift ;;
        --no-upgrade)  NO_UPGRADE=1; shift ;;
        --force)       FORCE=1; shift ;;
        --check)       CHECK_ONLY=1; shift ;;
        --system)      SYSTEM=1; shift ;;
        -h|--help)
            setup_colors; banner
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown flag: $1 (try -h)" >&2; exit 1 ;;
    esac
done

setup_colors
banner

# ── Privilege / install-location detection ─────────────────────
if [[ $EUID -eq 0 ]]; then
    SUDO=""; CAN_ROOT=1
elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"; CAN_ROOT=1
else
    SUDO=""; CAN_ROOT=0
    log_warn "No root/sudo — installing everything under \$HOME"
fi

if [[ $SYSTEM -eq 1 && $CAN_ROOT -eq 0 ]]; then
    log_err "--system needs root (install sudo or run as root) — aborting"
    exit 1
fi

if [[ $CAN_ROOT -eq 1 ]]; then
    GOROOT_DIR="/usr/local/go"; BINDIR="/usr/local/bin"
else
    GOROOT_DIR="$HOME/.local/go"; BINDIR="$HOME/.local/bin"
fi
mkdir -p "$BINDIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CROSSBOW_SRC="$SCRIPT_DIR/crossbow.sh"

FAILED=()
fail() { FAILED+=("$1"); log_err "$1: unresolved — see messages above"; }

# ── Helpers ────────────────────────────────────────────────────
# -a: tool banners (e.g. dalfox) embed non-text bytes that make grep go "binary"
extract_ver() { grep -aoE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1; }

# ver_ge A B  → true when version A >= version B
ver_ge() { [[ -n "${1:-}" ]] || return 1; printf '%s\n%s\n' "$2" "$1" | sort -V -C; }

# retry CMD...  → run up to 3 times with backoff (for flaky network installs)
retry() {
    local n=0 max=3
    until "$@"; do
        n=$((n + 1))
        (( n >= max )) && return 1
        log_warn "retrying (${n}/${max})…"; sleep 3
    done
}

# ask "question"  → 0=yes, 1=no. Honors -y / --no-upgrade / non-interactive.
ask() {
    [[ $WANT_UPGRADE -eq 1 || $ASSUME_YES -eq 1 ]] && return 0
    [[ $NO_UPGRADE -eq 1 ]] && return 1
    [[ -t 0 ]] || return 1
    local a; read -rp "$(echo -e "${YELLOW}[?]${RESET} $1 [y/N] ")" a
    [[ "$a" =~ ^[Yy] ]]
}

http_get() { # http_get URL OUTFILE
    if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
    else return 1; fi
}

# ── PATH wiring (current process + persisted) ──────────────────
ensure_path() {
    local gobin; gobin="$(go env GOPATH 2>/dev/null)/bin"
    [[ "$gobin" == "/bin" ]] && gobin="$HOME/go/bin"
    local entries=("$GOROOT_DIR/bin" "$gobin" "$HOME/.local/bin")

    for e in "${entries[@]}"; do
        [[ ":$PATH:" == *":$e:"* ]] || export PATH="$e:$PATH"
    done

    [[ $CHECK_ONLY -eq 1 ]] && return
    local marker="# crossbow toolchain PATH" rc
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [[ -f "$rc" ]] || continue
        grep -qF "$marker" "$rc" 2>/dev/null && continue
        {
            echo ""
            echo "$marker"
            echo "export PATH=\"$GOROOT_DIR/bin:\$(go env GOPATH 2>/dev/null)/bin:\$HOME/.local/bin:\$PATH\""
        } >> "$rc"
        log_info "Added PATH entries to ${rc/#$HOME/\~}"
    done
}

# ── Go toolchain ───────────────────────────────────────────────
go_version() { go version 2>/dev/null | extract_ver; }

install_go() {
    [[ $CHECK_ONLY -eq 1 ]] && { log_warn "go missing/old (check mode — skipping install)"; return 1; }
    local arch
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armv6l) arch="armv6l" ;;
        *) arch="amd64"; log_warn "Unknown arch $(uname -m) — assuming amd64" ;;
    esac
    local ver; ver="$(http_get "https://go.dev/VERSION?m=text" /dev/stdout 2>/dev/null | head -1)"
    [[ "$ver" =~ ^go ]] || ver="$GO_FALLBACK"
    local tarball="${ver}.linux-${arch}.tar.gz"
    local tmp; tmp="$(mktemp -d)"
    log_info "Downloading $tarball …"
    if ! retry http_get "https://go.dev/dl/${tarball}" "$tmp/$tarball"; then
        log_err "Failed to download Go tarball"; rm -rf "$tmp"; return 1
    fi
    log_info "Installing Go into $GOROOT_DIR …"
    $SUDO rm -rf "$GOROOT_DIR"
    $SUDO mkdir -p "$(dirname "$GOROOT_DIR")"
    $SUDO tar -C "$(dirname "$GOROOT_DIR")" -xzf "$tmp/$tarball"
    rm -rf "$tmp"
    export PATH="$GOROOT_DIR/bin:$PATH"
    command -v go >/dev/null 2>&1
}

ensure_go() {
    log_step "Go toolchain"
    export PATH="$GOROOT_DIR/bin:$PATH"
    local cur; cur="$(go_version)"
    if [[ $FORCE -eq 1 && $CHECK_ONLY -eq 0 ]]; then
        log_warn "go: --force reinstall"; install_go || { fail "go"; return; }
    elif [[ -z "$cur" ]]; then
        log_info "go not found — installing"; install_go || { fail "go"; return; }
    elif ! ver_ge "$cur" "$GO_MIN"; then
        log_warn "go $cur < $GO_MIN — upgrading"; install_go || { fail "go"; return; }
    else
        log_ok "go $cur (>= $GO_MIN)"
        if [[ $CHECK_ONLY -eq 0 ]] && ask "Upgrade Go to the latest release?"; then
            install_go || log_warn "Go upgrade failed — keeping $cur"
        fi
    fi
    cur="$(go_version)"
    [[ -n "$cur" ]] && log_ok "go ready ($cur)" || fail "go"
}

# ── pipx ───────────────────────────────────────────────────────
ensure_pipx() {
    log_step "pipx"
    if command -v pipx >/dev/null 2>&1; then
        log_ok "pipx $(pipx --version 2>/dev/null)"
    elif [[ $CHECK_ONLY -eq 1 ]]; then
        log_warn "pipx missing (check mode — skipping install)"; fail "pipx"; return
    else
        log_info "Installing pipx …"
        if python3 -m pip install --user --break-system-packages -q pipx 2>/dev/null; then
            log_ok "pipx installed via pip"
        elif [[ $CAN_ROOT -eq 1 ]] && $SUDO apt-get install -y pipx >/dev/null 2>&1; then
            log_ok "pipx installed via apt"   # single-package install — no apt update/upgrade
        else
            fail "pipx"; return
        fi
    fi
    export PATH="$HOME/.local/bin:$PATH"
    [[ $CHECK_ONLY -eq 0 ]] && { python3 -m pipx ensurepath >/dev/null 2>&1 || pipx ensurepath >/dev/null 2>&1 || true; }
}

# ── Generic Go-tool installer (katana / dalfox) ───────────────
go_install() { # go_install MODULE@latest NAME
    [[ $CHECK_ONLY -eq 1 ]] && { log_warn "$2: would install $1 (check mode)"; return 1; }
    command -v go >/dev/null 2>&1 || { log_err "$2: Go unavailable"; return 1; }
    log_info "go install $1 …"
    retry env GOFLAGS="-buildvcs=false" GOTOOLCHAIN=auto go install "$1"
}

# Copy a freshly-built user binary into /usr/local/bin (so root + every user gets it)
system_place() { # NAME
    [[ $SYSTEM -eq 1 && $CHECK_ONLY -eq 0 ]] || return 0
    local name="$1" gobin
    gobin="$(go env GOPATH 2>/dev/null)/bin"; [[ "$gobin" == "/bin" ]] && gobin="$HOME/go/bin"
    [[ -x "$gobin/$name" ]] || return 0
    if $SUDO install -m 0755 "$gobin/$name" "/usr/local/bin/$name" 2>/dev/null; then
        log_ok "$name → /usr/local/bin (system-wide)"
    else
        log_warn "$name: could not copy to /usr/local/bin"
    fi
}

ensure_go_tool() { # NAME MIN MODULE VERFN
    local name="$1" min="$2" module="$3" verfn="$4" cur
    log_step "$name"
    cur="$($verfn)"
    if [[ $FORCE -eq 1 ]]; then
        log_warn "$name: --force reinstall"; go_install "$module" "$name" || { fail "$name"; return; }
    elif [[ -z "$cur" ]]; then
        if command -v "$name" >/dev/null 2>&1; then
            log_warn "$name present but not responding — healing"
        else
            log_info "$name not found — installing"
        fi
        go_install "$module" "$name" || { fail "$name"; return; }
    elif ! ver_ge "$cur" "$min"; then
        log_warn "$name $cur < $min — upgrading"; go_install "$module" "$name" || { fail "$name"; return; }
    else
        log_ok "$name $cur (>= $min)"
        if ask "Upgrade $name to latest?"; then
            go_install "$module" "$name" || log_warn "$name upgrade failed — keeping $cur"
        fi
    fi
    system_place "$name"
    cur="$($verfn)"
    if command -v "$name" >/dev/null 2>&1 && [[ -n "$cur" ]]; then
        log_ok "$name ready ($cur)"
    elif [[ $CHECK_ONLY -eq 1 ]]; then
        FAILED+=("$name")
    else
        fail "$name"
    fi
}

katana_version() { katana -version 2>&1 | extract_ver; }
# dalfox prints its version banner to stderr, so capture 2>&1
dalfox_version() { { dalfox version 2>&1 || dalfox --version 2>&1; } | extract_ver; }

# ── arjun (pipx) ───────────────────────────────────────────────
arjun_version() {
    # arjun has no --version flag; read it from its own venv (works for user & --global, no sudo)
    local v shebang py
    if command -v arjun >/dev/null 2>&1; then
        shebang="$(head -1 "$(command -v arjun)" 2>/dev/null)"; py="${shebang#\#!}"
        [[ -x "$py" ]] && v="$("$py" -c 'import importlib.metadata as m; print(m.version("arjun"))' 2>/dev/null)"
    fi
    [[ -z "$v" ]] && v="$(pipx list --short 2>/dev/null | awk '/^arjun/{print $2; exit}')"
    echo "$v"
}

ensure_arjun() {
    log_step "arjun"
    command -v pipx >/dev/null 2>&1 || { log_err "arjun: pipx unavailable"; fail "arjun"; return; }
    # pipx target: --global (root + all users, bins in /usr/local/bin) for --system, else per-user
    local pipx_pre=() gflag=""
    [[ $SYSTEM -eq 1 ]] && { pipx_pre=($SUDO); gflag="--global"; }

    local cur; cur="$(arjun_version)"
    local installed=0
    if [[ $SYSTEM -eq 1 ]]; then
        [[ -x /usr/local/bin/arjun ]] && installed=1
    else
        pipx list --short 2>/dev/null | grep -q '^arjun' && installed=1
    fi

    if [[ $CHECK_ONLY -eq 1 ]]; then
        if command -v arjun >/dev/null 2>&1 && arjun -h >/dev/null 2>&1; then
            log_ok "arjun ${cur:-?}"
        else
            log_warn "arjun missing/broken"; FAILED+=("arjun")
        fi
        return
    fi

    if [[ $FORCE -eq 1 && $installed -eq 1 ]]; then
        log_warn "arjun: --force reinstall"; retry "${pipx_pre[@]}" pipx reinstall $gflag arjun || { fail "arjun"; return; }
    elif [[ $installed -eq 0 ]]; then
        log_info "Installing arjun via pipx ${gflag:+(global) }…"
        retry "${pipx_pre[@]}" pipx install $gflag arjun || { fail "arjun"; return; }
    elif [[ -n "$cur" ]] && ! ver_ge "$cur" "$ARJUN_MIN"; then
        log_warn "arjun $cur < $ARJUN_MIN — upgrading"; retry "${pipx_pre[@]}" pipx upgrade $gflag arjun || { fail "arjun"; return; }
    else
        log_ok "arjun ${cur:-installed} (>= $ARJUN_MIN)"
        if ask "Upgrade arjun to latest?"; then
            "${pipx_pre[@]}" pipx upgrade $gflag arjun >/dev/null 2>&1 || log_warn "arjun upgrade failed — keeping ${cur:-current}"
        fi
    fi

    export PATH="$HOME/.local/bin:$PATH"
    if command -v arjun >/dev/null 2>&1 && arjun -h >/dev/null 2>&1; then
        log_ok "arjun ready ($(arjun_version))"
    else
        fail "arjun"
    fi
}

# ── python3 ────────────────────────────────────────────────────
ensure_python() {
    log_step "python3"
    local cur; cur="$(python3 --version 2>&1 | extract_ver)"
    if [[ -z "$cur" ]]; then
        log_err "python3 not found — install it first (apt-get install -y python3)"
        fail "python3"; return
    fi
    if ver_ge "$cur" "$PY_MIN"; then
        log_ok "python3 $cur (>= $PY_MIN)"
    else
        log_warn "python3 $cur < $PY_MIN (crossbow may misbehave)"
    fi
}

# ── Install crossbow itself ────────────────────────────────────
ensure_crossbow() {
    log_step "crossbow command"
    if [[ ! -f "$CROSSBOW_SRC" ]]; then
        log_err "crossbow.sh not found next to install.sh ($CROSSBOW_SRC)"; fail "crossbow"; return
    fi
    [[ $CHECK_ONLY -eq 1 ]] || chmod +x "$CROSSBOW_SRC"
    local link="$BINDIR/crossbow"
    local sd=""; [[ "$BINDIR" == /usr/* && $CAN_ROOT -eq 1 ]] && sd="$SUDO"

    if [[ $CHECK_ONLY -eq 1 ]]; then
        if command -v crossbow >/dev/null 2>&1; then log_ok "crossbow on PATH ($(command -v crossbow))"
        else log_warn "crossbow not linked yet"; fi
        return
    fi
    if $sd ln -sf "$CROSSBOW_SRC" "$link" 2>/dev/null; then
        log_ok "Linked $link → crossbow.sh"
    else
        log_warn "Could not write $link — falling back to \$HOME/.local/bin"
        ln -sf "$CROSSBOW_SRC" "$HOME/.local/bin/crossbow" && log_ok "Linked ~/.local/bin/crossbow"
    fi
}

# ── Run ────────────────────────────────────────────────────────
[[ $CHECK_ONLY -eq 1 ]] && log_info "Running in ${BOLD}--check${RESET} mode (no changes will be made)"
if [[ $SYSTEM -eq 1 ]]; then
    log_info "Mode: ${BOLD}system-wide${RESET} — tools go to /usr/local/bin (root + all users)"
else
    log_info "Mode: ${BOLD}user${RESET} — tools go to ~/go/bin & ~/.local/bin (run with ${BOLD}--system${RESET} for root-wide)"
fi

ensure_python
ensure_go
ensure_path        # now that go exists, GOPATH/bin can be resolved & persisted
ensure_pipx
ensure_go_tool katana "$KATANA_MIN" "github.com/projectdiscovery/katana/cmd/katana@latest" katana_version
ensure_go_tool dalfox "$DALFOX_MIN" "github.com/hahwul/dalfox/v2@latest"                  dalfox_version
ensure_arjun
ensure_crossbow

# ── Summary ────────────────────────────────────────────────────
echo "" >&2
echo -e "${BOLD}══════════════════════════════════════════${RESET}" >&2
echo -e "${BOLD}  TOOLCHAIN STATUS${RESET}" >&2
echo -e "──────────────────────────────────────────" >&2
status_line() { # NAME VERSTRING
    if [[ -n "$2" ]] && command -v "$1" >/dev/null 2>&1; then
        printf "  ${GREEN}[+]${RESET} %-9s ${DIM}%s${RESET}\n" "$1" "$2" >&2
    else
        printf "  ${RED}[-]${RESET} %-9s ${DIM}missing${RESET}\n" "$1" >&2
    fi
}
status_line python3 "$(python3 --version 2>&1 | extract_ver)"
status_line go      "$(go_version)"
status_line katana  "$(katana_version)"
status_line dalfox  "$(dalfox_version)"
status_line arjun   "$(arjun_version)"
echo -e "──────────────────────────────────────────" >&2

if [[ ${#FAILED[@]} -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All tools ready.${RESET}" >&2
    if [[ $CHECK_ONLY -eq 0 ]]; then
        echo -e "  ${DIM}Open a new shell (or 'source ~/.bashrc') so PATH updates take effect.${RESET}" >&2
        if [[ $SYSTEM -eq 1 ]]; then
            echo -e "  ${DIM}Tools are in /usr/local/bin — works for your user and ${BOLD}sudo crossbow${RESET}${DIM} too.${RESET}" >&2
        fi
        echo -e "  Run: ${BOLD}crossbow -u https://target.com -H cookies.txt${RESET}" >&2
    fi
    echo -e "${BOLD}══════════════════════════════════════════${RESET}" >&2
    exit 0
else
    echo -e "  ${RED}${BOLD}Unresolved:${RESET} ${FAILED[*]}" >&2
    echo -e "  ${DIM}Re-run ./install.sh to retry (it is idempotent & self-healing).${RESET}" >&2
    echo -e "${BOLD}══════════════════════════════════════════${RESET}" >&2
    exit 1
fi
