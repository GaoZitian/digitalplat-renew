#!/usr/bin/env python3
"""
DigitalPlat API helper — bypasses Cloudflare challenge via cloudscraper.
Usage:
  python3 digitalplat_api_helper.py <endpoint> <auth_token> [--method GET|POST] [--body '{"k":"v"}'] [--debug]
  endpoint: e.g. /domains  or  /domains/example.com/renew
  auth_token: Bearer token (already includes 'Bearer ')
  --method: HTTP method (default GET); POST sends JSON body
  --body:   JSON string for POST body, e.g. '{"renewal_type":"free","years":1}'
  --debug:  also print raw response to stderr for inspection

Output: JSON response on stdout, errors/debug info on stderr, exit code 0/1.
"""

import sys
import json
import os

try:
    import cloudscraper
    HAS_CLOUDSCRAPER = True
except ImportError:
    HAS_CLOUDSCRAPER = False

API_BASE = "https://domain-api.digitalplat.org/api/v1"

def fetch_with_cloudscraper(url, headers, method="GET", body=None):
    """Use cloudscraper to bypass Cloudflare challenge."""
    scraper = cloudscraper.create_scraper(
        browser={'browser': 'chrome', 'platform': 'linux', 'desktop': True}
    )
    if method == "POST":
        response = scraper.post(url, headers=headers, json=body, timeout=30)
    else:
        response = scraper.get(url, headers=headers, timeout=30)
    if response.status_code >= 400:
        print(f"Error: HTTP {response.status_code}", file=sys.stderr)
        print(response.text[:1000], file=sys.stderr)
        sys.exit(1)
    return response.text

def fetch_with_urllib(url, headers, method="GET", body=None):
    """Fallback: standard urllib (no Cloudflare bypass)."""
    import urllib.request
    import urllib.error
    data = None
    if method == "POST":
        data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method)
    for k, v in headers.items():
        req.add_header(k, v)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.read().decode('utf-8')
    except urllib.error.HTTPError as e:
        print(f"Error: HTTP {e.code}", file=sys.stderr)
        print(e.read().decode('utf-8', errors='replace')[:1000], file=sys.stderr)
        sys.exit(1)

def main():
    args = sys.argv[1:]
    debug = '--debug' in args
    if debug:
        args = [a for a in args if a != '--debug']

    method = "GET"
    body = None
    if '--method' in args:
        i = args.index('--method')
        method = args[i + 1].upper()
        del args[i:i + 2]
    if '--body' in args:
        i = args.index('--body')
        body = json.loads(args[i + 1])
        del args[i:i + 2]

    if len(args) < 2:
        print("Usage: digitalplat_api_helper.py <endpoint> <auth_token> [--method GET|POST] [--body '...'] [--debug]", file=sys.stderr)
        sys.exit(1)

    endpoint = args[0]
    auth_token = args[1]
    url = f"{API_BASE}{endpoint}"
    headers = {"Authorization": auth_token, "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"}
    if method == "POST":
        headers["Content-Type"] = "application/json"

    if HAS_CLOUDSCRAPER:
        body_out = fetch_with_cloudscraper(url, headers, method, body)
    else:
        print("Warning: cloudscraper not installed, falling back to urllib", file=sys.stderr)
        body_out = fetch_with_urllib(url, headers, method, body)

    if debug:
        print(f"RAW RESPONSE:\n{body_out}", file=sys.stderr)

    # Validate JSON
    try:
        parsed = json.loads(body_out)
    except json.JSONDecodeError as e:
        print(f"Error: Response is not valid JSON: {e}", file=sys.stderr)
        print(body_out[:1000], file=sys.stderr)
        sys.exit(1)

    # Output valid JSON on stdout
    print(json.dumps(parsed, ensure_ascii=False, separators=(',', ':')))

if __name__ == "__main__":
    main()
