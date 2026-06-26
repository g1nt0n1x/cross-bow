#!/bin/bash
# install.sh — one-shot installer + doctor for the crossbow toolchain.
#
#   chmod +x install.sh && ./install.sh
#
# Installs (or upgrades) go · katana · dalfox · arjun system-wide into
# /usr/local/bin, so your user AND root (`sudo crossbow`) can use them.
# Run it again any time — it heals whatever is broken and offers upgrades.
# It auto-elevates with sudo and never runs `apt update`/`apt upgrade`
# (that breaks rolling Kali).
#
#   ./install.sh        install / upgrade / heal  (asks before upgrading)
#   ./install.sh -y     same, but non-interactive — yes to everything
#   ./install.sh -h     this help
#
set -uo pipefail

# ── Minimum acceptable versions ────────────────────────────────
GO_MIN="1.21.0"  KATANA_MIN="1.0.5"  DALFOX_MIN="2.9.0"  ARJUN_MIN="2.2.0"  PY_MIN="3.8.0"
GO_FALLBACK="go1.22.5"   # used only if go.dev is unreachable

# ── Colors & logging ───────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi
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
usage() {
    banner
    sed -n '4,14p' "$0" | sed 's/^# \{0,1\}//'
}

# ── Args (only -y and -h) ──────────────────────────────────────
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes)  ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $arg (try -h)" >&2; exit 1 ;;
    esac
done

# ── Self-elevate: everything runs as root so it lands system-wide ──
if [[ $EUID -ne 0 ]]; then
    log_info "Re-running with sudo (system-wide install)…"
    SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    exec sudo -E bash "$SELF" "$@"
fi

banner

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CROSSBOW_SRC="$SCRIPT_DIR/crossbow.sh"
export PATH="/usr/local/go/bin:$PATH"

FAILED=()
fail() { FAILED+=("$1"); log_err "$1: unresolved — see above"; }

# ── Helpers ────────────────────────────────────────────────────
# -a: tool banners (dalfox) embed non-text bytes that make grep go "binary"
extract_ver() { grep -aoE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1; }
ver_ge() { [[ -n "${1:-}" ]] || return 1; printf '%s\n%s\n' "$2" "$1" | sort -V -C; }
retry()  { local n=0; until "$@"; do n=$((n+1)); (( n>=3 )) && return 1; log_warn "retry ($n/3)…"; sleep 3; done; }

# yes when -y, otherwise prompt; default No; non-interactive without -y → No
ask() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    [[ -t 0 ]] || return 1
    local a; read -rp "$(echo -e "${YELLOW}[?]${RESET} $1 [y/N] ")" a
    [[ "$a" =~ ^[Yy] ]]
}

# ── Version probes ─────────────────────────────────────────────
go_version()     { go version 2>/dev/null | extract_ver; }
katana_version() { katana -version 2>&1 | extract_ver; }
dalfox_version() { dalfox version 2>&1 | extract_ver; }   # dalfox prints to stderr
python_version() { python3 --version 2>&1 | extract_ver; }
arjun_version() {
    # arjun has no --version flag; read it straight from its own venv
    local v sb py
    if command -v arjun >/dev/null 2>&1; then
        sb="$(head -1 "$(command -v arjun)" 2>/dev/null)"; py="${sb#\#!}"
        [[ -x "$py" ]] && v="$("$py" -c 'import importlib.metadata as m;print(m.version("arjun"))' 2>/dev/null)"
    fi
    echo "${v:-}"
}

# ── python3 (must already exist on Kali) ───────────────────────
ensure_python() {
    log_step "python3"
    local cur; cur="$(python_version)"
    if [[ -z "$cur" ]]; then
        log_err "python3 missing — install it: apt-get install -y python3"; fail "python3"; return
    fi
    ver_ge "$cur" "$PY_MIN" && log_ok "python3 $cur" || log_warn "python3 $cur < $PY_MIN (may misbehave)"
}

# ── Go toolchain (into /usr/local/go) ──────────────────────────
install_go() {
    local arch
    case "$(uname -m)" in
        x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;;
        armv7l|armv6l) arch=armv6l ;; *) arch=amd64; log_warn "unknown arch — assuming amd64" ;;
    esac
    local ver; ver="$(curl -fsSL 'https://go.dev/VERSION?m=text' 2>/dev/null | head -1)"
    [[ "$ver" == go* ]] || ver="$GO_FALLBACK"
    local tb="${ver}.linux-${arch}.tar.gz" tmp; tmp="$(mktemp -d)"
    log_info "downloading $tb …"
    retry curl -fsSL -o "$tmp/$tb" "https://go.dev/dl/$tb" || { rm -rf "$tmp"; return 1; }
    rm -rf /usr/local/go && tar -C /usr/local -xzf "$tmp/$tb"; rm -rf "$tmp"
    export PATH="/usr/local/go/bin:$PATH"
    echo 'export PATH="$PATH:/usr/local/go/bin"' > /etc/profile.d/crossbow.sh 2>/dev/null || true
    command -v go >/dev/null 2>&1
}
ensure_go() {
    log_step "Go toolchain"
    local cur; cur="$(go_version)"
    if [[ -z "$cur" ]]; then
        log_info "Go not found — installing"; install_go || { fail "go"; return; }
    elif ! ver_ge "$cur" "$GO_MIN"; then
        log_warn "go $cur < $GO_MIN — upgrading"; install_go || { fail "go"; return; }
    else
        log_ok "go $cur"
        ask "Upgrade Go to latest?" && { install_go || log_warn "Go upgrade failed — keeping $cur"; }
    fi
    cur="$(go_version)"; [[ -n "$cur" ]] && log_ok "go ready ($cur)" || fail "go"
}

# ── pipx ───────────────────────────────────────────────────────
ensure_pipx() {
    log_step "pipx"
    if command -v pipx >/dev/null 2>&1; then
        log_ok "pipx $(pipx --version 2>/dev/null)"
    elif apt-get install -y pipx >/dev/null 2>&1; then        # single pkg — not apt upgrade
        log_ok "pipx installed"
    elif python3 -m pip install --break-system-packages -q pipx 2>/dev/null; then
        log_ok "pipx installed (pip)"
    else
        fail "pipx"
    fi
}

# ── Go tools straight into /usr/local/bin (GOBIN) ──────────────
gobuild() { # MODULE NAME
    command -v go >/dev/null 2>&1 || { log_err "$2: Go unavailable"; return 1; }
    log_info "building $2 …"
    retry env GOBIN=/usr/local/bin GOFLAGS=-buildvcs=false GOTOOLCHAIN=auto go install "$1"
}
ensure_go_tool() { # NAME MIN MODULE VERFN
    local name="$1" min="$2" module="$3" verfn="$4" cur
    log_step "$name"
    cur="$($verfn)"
    if [[ -z "$cur" ]]; then
        command -v "$name" >/dev/null 2>&1 && log_warn "$name broken — reinstalling" || log_info "$name not found — installing"
        gobuild "$module" "$name" || { fail "$name"; return; }
    elif ! ver_ge "$cur" "$min"; then
        log_warn "$name $cur < $min — upgrading"; gobuild "$module" "$name" || { fail "$name"; return; }
    else
        log_ok "$name $cur"
        ask "Upgrade $name to latest?" && { gobuild "$module" "$name" || log_warn "$name upgrade failed — keeping $cur"; }
    fi
    cur="$($verfn)"
    command -v "$name" >/dev/null 2>&1 && [[ -n "$cur" ]] && log_ok "$name ready ($cur)" || fail "$name"
}

# ── arjun (pipx --global → /usr/local/bin) ─────────────────────
ensure_arjun() {
    log_step "arjun"
    command -v pipx >/dev/null 2>&1 || { log_err "arjun: pipx unavailable"; fail "arjun"; return; }
    local cur; cur="$(arjun_version)"
    if [[ ! -x /usr/local/bin/arjun ]]; then
        log_info "installing arjun (pipx --global) …"
        retry pipx install --global arjun || { fail "arjun"; return; }
    elif [[ -n "$cur" ]] && ! ver_ge "$cur" "$ARJUN_MIN"; then
        log_warn "arjun $cur < $ARJUN_MIN — upgrading"; retry pipx upgrade --global arjun || { fail "arjun"; return; }
    else
        log_ok "arjun ${cur:-installed}"
        ask "Upgrade arjun to latest?" && { pipx upgrade --global arjun >/dev/null 2>&1 || log_warn "arjun upgrade failed"; }
    fi
    command -v arjun >/dev/null 2>&1 && arjun -h >/dev/null 2>&1 && log_ok "arjun ready ($(arjun_version))" || fail "arjun"
}

# ── crossbow command ───────────────────────────────────────────
ensure_crossbow() {
    log_step "crossbow command"
    [[ -f "$CROSSBOW_SRC" ]] || { log_err "crossbow.sh not found ($CROSSBOW_SRC)"; fail "crossbow"; return; }
    chmod +x "$CROSSBOW_SRC"
    ln -sf "$CROSSBOW_SRC" /usr/local/bin/crossbow && log_ok "linked /usr/local/bin/crossbow → crossbow.sh" || fail "crossbow"
}

# ── Run ────────────────────────────────────────────────────────
ensure_python
ensure_go
ensure_pipx
ensure_go_tool katana "$KATANA_MIN" "github.com/projectdiscovery/katana/cmd/katana@latest" katana_version
ensure_go_tool dalfox "$DALFOX_MIN" "github.com/hahwul/dalfox/v2@latest"                  dalfox_version
ensure_arjun
ensure_crossbow

# ── Summary ────────────────────────────────────────────────────
status_line() {
    if [[ -n "$2" ]] && command -v "$1" >/dev/null 2>&1; then
        printf "  ${GREEN}[+]${RESET} %-9s ${DIM}%s${RESET}\n" "$1" "$2" >&2
    else
        printf "  ${RED}[-]${RESET} %-9s ${DIM}missing${RESET}\n" "$1" >&2
    fi
}
echo "" >&2
echo -e "${BOLD}══════════════════════════════════════════${RESET}" >&2
echo -e "${BOLD}  TOOLCHAIN STATUS${RESET}" >&2
echo -e "──────────────────────────────────────────" >&2
status_line python3 "$(python_version)"
status_line go      "$(go_version)"
status_line katana  "$(katana_version)"
status_line dalfox  "$(dalfox_version)"
status_line arjun   "$(arjun_version)"
echo -e "──────────────────────────────────────────" >&2
if [[ ${#FAILED[@]} -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All tools ready.${RESET}  ${DIM}(re-run anytime to heal/upgrade)${RESET}" >&2
    echo -e "  Run: ${BOLD}crossbow -u https://target.com -H cookies.txt${RESET}" >&2
    echo -e "${BOLD}══════════════════════════════════════════${RESET}" >&2
    exit 0
else
    echo -e "  ${RED}${BOLD}Unresolved:${RESET} ${FAILED[*]}  ${DIM}— re-run to retry${RESET}" >&2
    echo -e "${BOLD}══════════════════════════════════════════${RESET}" >&2
    exit 1
fi
