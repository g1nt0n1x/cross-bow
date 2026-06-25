# Crossbow

XSS recon pipeline that chains **katana** (crawling) + **arjun** (parameter discovery) + **dalfox** (XSS scanning) into a single automated workflow.

```
   \\     //
    \\═══//
 ════╬═●═╬════►  crossbow v1.0.0
    //═══\\
   //     \\     katana + arjun + dalfox
```

## Install

Requires: `katana`, `arjun`, `dalfox`, `python3`

```bash
# Already installed at /opt/crossbow
# Available system-wide as: crossbow
```

## Usage

```bash
crossbow -u <url> [options]
```

### Quick Examples

```bash
# Standard scan with auth cookies
crossbow -u https://target.com -H cookies.txt

# Deep scan — thorough crawl, all encoders, extended payloads
crossbow -u https://target.com -H cookies.txt --deep

# Sonic — max speed, parallel phases, high concurrency
crossbow -u https://target.com -H cookies.txt --sonic

# Stealth — low and slow, WAF-friendly
crossbow -u https://target.com -H cookies.txt --stealth --waf

# All profiles — run quick+standard+deep+sonic, merge & deduplicate
crossbow -u https://target.com -H cookies.txt --all

# Resume from a previous crawl
crossbow -u https://target.com --skip-crawl --crawl-file urls.txt

# Blind XSS with OOB callback
crossbow -u https://target.com --blind https://your.callback.url --oob
```

## Scan Profiles

| Profile | Crawl Depth | Dalfox Workers | Best For |
|---------|-------------|----------------|----------|
| `--quick` | 2 (shallow) | 20 | Fast first pass |
| `--standard` | 3 | 30 | Default balanced scan |
| `--deep` | 5 (+ JS links, form fill) | 50 | Completeness — finds deep paths |
| `--stealth` | 3 (rate-limited) | 5 | WAF-protected targets |
| `--sonic` | 2 (broad, 50 concurrent) | 100 | Max speed, parallel arjun+dalfox |
| `--all` | all of the above | all | Run all 4 profiles, merge & deduplicate |

### Profile Details

- **Standard** (default): Balanced crawl depth, tech detection, known-files. Sequential arjun then dalfox.
- **Deep**: Depth 5 crawl with JS link analysis and auto form-fill. HPP, external JS analysis, remote payloads (portswigger + payloadbox), follow redirects, 500 payloads per param. Finds things other profiles miss on sites with deep directory structures.
- **Sonic**: Broad but shallow crawl. Runs arjun and dalfox in parallel. Skips mining, WAF probing, and reflection analysis for pure speed. Second dalfox pass on arjun-discovered params.
- **Stealth**: Rate-limited across all tools (5 req/s katana, 1 arjun thread, 5 dalfox workers with 500ms delay). WAF evasion enabled. Passive arjun recon.

## Features

### CB Recheck (Crossbow Recheck)

After scanning, crossbow automatically rechecks `[V]` findings that rely on interaction-dependent events (mouseover, focus, click, etc.). These often produce false positives on hidden inputs. The recheck retests with a self-executing `"><svg/onload=alert(1)>` tag-breakout payload and reports confirmed findings as `[CB][V]`.

### Stored XSS Candidate Discovery

Discovers POST forms with text inputs that may store data (comments, messages, profiles). Outputs to `stored_xss_candidates.txt` for manual testing. Automatically filters out login/registration/settings forms.

### No-Headers Warning

Warns when running without `-H` headers, since many targets require authentication cookies.

## Options

```
TARGET
    -u, --target <url>        Target URL (required)
    -H, --headers <val>       Header string or file (repeatable)

PROFILES
    --quick                   Fast scan: shallow crawl, small wordlist
    --standard                Balanced (default)
    --deep                    Thorough: headless crawl, all encoders, deep scan
    --stealth                 Low & slow: rate-limited, WAF-friendly
    --sonic                   Max speed: parallel phases, high concurrency
    --all                     Run all profiles (quick+standard+deep+sonic), merge results

FEATURES
    --blind <url>             Blind XSS callback URL
    --oob                     Enable interactsh OOB for blind XSS
    --sxss <url>              Stored XSS — check this URL for reflection
    --proxy <url>             Proxy for all tools (http/socks5)
    --waf                     Enable WAF evasion across pipeline
    --passive                 Enable arjun passive recon (wayback/commoncrawl)

PHASE CONTROL
    --skip-crawl              Skip katana crawl phase
    --skip-arjun              Skip arjun discovery phase
    --skip-scan               Skip dalfox scan phase
    --crawl-file <file>       Use existing URL list instead of crawling

OUTPUT
    -o, --output-dir <dir>    Output directory (default: ~/.crossbow/<timestamp>_<host>)
    -f, --format <fmt>        Dalfox format: plain|json|jsonl|sarif|markdown
    -T, --threads <n>         Parallel arjun instances + dalfox target concurrency
    --no-color                Disable colored output
    -q, --quiet               Minimal output
    -vv, --verbose            Verbose: show full tool output + dalfox debug
```

## Output

Results are saved to `~/.crossbow/<timestamp>_<host>/`:

| File | Contents |
|------|----------|
| `crawled.txt` | All URLs found by katana |
| `paths.txt` | Unique paths (query strings stripped) |
| `arjun.json` | Raw arjun parameter discovery results |
| `enriched.txt` | URLs with arjun-discovered parameters appended |
| `targets.txt` | Final merged target list |
| `results.txt` | Dalfox findings (format depends on `-f`) |
| `stored_xss_candidates.txt` | POST forms for manual stored XSS testing |

## Reading Results

In plain format, findings are tagged:

- `[POC][V]` — Verified: payload confirmed in DOM
- `[POC][R]` — Reflected: payload text reflected but not confirmed executable
- `[POC][A]` — DOM-based: identified via AST analysis
- `[CB][V]` — Crossbow recheck: tag-breakout payload confirmed (self-executing, high confidence)
