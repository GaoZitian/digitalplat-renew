#!/usr/bin/env bash
# DigitalPlat Domain Renewal Checker + Auto Renew
# API: https://domain-api.digitalplat.org/api/v1
#
# 流程:
#   1. GET  /domains                     拉取全部域名
#   2. 判断是否进入续期窗口 (到期前 RENEWAL_WINDOW_DAYS 天，含已过期)
#   3. POST /domains/{domain}/renew      对窗口内域名自动免费续期
#      body: {"renewal_type":"free","years":1}
#   4. GET  /domains                     续期后重新读取权威状态
#   5. Telegram 通知: 列出全部域名 + 到期时间 + 剩余天数 + 续期结果
#
# Cloudflare bypass: cloudscraper Python helper (digitalplat_api_helper.py)
# 日期计算: python3 (跨平台，不依赖 GNU date -d)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/digitalplat_api_helper.py"
API_BASE="https://domain-api.digitalplat.org/api/v1"

RENEWAL_WINDOW_DAYS="${RENEWAL_WINDOW_DAYS:-120}"  # DigitalPlat 政策：到期前 120 天内可免费续期
RENEWAL_TYPE="${RENEWAL_TYPE:-free}"
RENEWAL_YEARS="${RENEWAL_YEARS:-1}"
DRY_RUN="${DRY_RUN:-0}"                          # DRY_RUN=1 只检查不续期

# 检查依赖
if ! python3 -c "import cloudscraper" 2>/dev/null; then
    echo "错误: 缺少 cloudscraper，运行: pip3 install cloudscraper" >&2
    exit 1
fi
command -v jq >/dev/null || { echo "错误: 缺少依赖 jq" >&2; exit 1; }

API_KEY="${DIGITALPLAT_API_KEY:?错误: 请先设置环境变量 DIGITALPLAT_API_KEY}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?错误: 请先设置环境变量 TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:?错误: 请先设置环境变量 TELEGRAM_CHAT_ID}"

# 拉取域名列表 -> 规范化为 TSV: name \t status \t expiry \t can_renew
fetch_domains() {
    local response payload
    echo "正在获取域名列表..." >&2
    response=$(python3 "$HELPER" "/domains" "Bearer ${API_KEY}" 2>/dev/null) || {
        echo "错误: 获取域名列表失败" >&2
        return 1
    }

    if jq -e 'type == "array"' <<<"$response" >/dev/null 2>&1; then
        payload="$response"
    elif jq -e '.success == true and (.data | type == "array")' <<<"$response" >/dev/null 2>&1; then
        payload=$(jq '.data' <<<"$response")
    elif jq -e '.data | type == "array"' <<<"$response" >/dev/null 2>&1; then
        payload=$(jq '.data' <<<"$response")
    elif jq -e '.domains | type == "array"' <<<"$response" >/dev/null 2>&1; then
        payload=$(jq '.domains' <<<"$response")
    else
        echo "错误: 无法解析 API 响应" >&2
        echo "原始响应: ${response:0:800}" >&2
        return 1
    fi

    jq -r '(. // [])[] | [
        (.name // .domain // .full_domain // ""),
        (.status // .state // ""),
        (.expiry_date // .expires_at // .expiry // .expire // .expiration_date // ""),
        (if (.can_renew? != null) then .can_renew elif (.can_free_renew? != null) then .can_free_renew elif (.renewable? != null) then .renewable else "" end)
    ] | @tsv' <<<"$payload" | while IFS=$'\t' read -r n s e c; do
        [[ -z "$n" || "$n" == "null" ]] && continue
        printf '%s\t%s\t%s\t%s\n' "$n" "$s" "$e" "$c"
    done
}

# 计算到期信息。输出三列: days<TAB>in_window<TAB>permanent
#   days: 整数，剩余天数；已过期为负数
#   in_window: yes/no  (含已过期 -> yes)
#   permanent: yes/no  (永久/无效 -> permanent=yes, days=-1, in_window=no)
calc_expiry() {
    python3 - "$1" "$RENEWAL_WINDOW_DAYS" <<'PY'
import sys
from datetime import datetime, timezone

expiry = (sys.argv[1] or "").strip()
window = int(sys.argv[2])

if not expiry or expiry.lower() in ("null", "none", "permanent", "永久", "lifetime"):
    print("-1\tno\tyes")
    sys.exit(0)

dt = None
for fmt in ("%Y-%m-%d", "%Y%m%d", "%Y-%m-%d %H:%M:%S"):
    try:
        dt = datetime.strptime(expiry, fmt).replace(tzinfo=timezone.utc)
        break
    except ValueError:
        continue
if dt is None:
    try:
        dt = datetime.fromisoformat(expiry.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
    except ValueError:
        print("-1\tno\tyes")
        sys.exit(0)

days = (dt.date() - datetime.now(timezone.utc).date()).days
in_window = "yes" if days <= window else "no"
print(f"{days}\t{in_window}\tno")
PY
}

echo "===== 阶段 1: 读取域名清单 =====" >&2
raw_tsv=$(fetch_domains) || exit 1

if [[ -z "$raw_tsv" ]]; then
    echo "错误: 域名清单为空" >&2
    exit 1
fi

echo "已获取 $(wc -l <<<"$raw_tsv" | tr -d ' ') 个域名" >&2

# 分类: 需续期 / 跳过
declare -a renew_targets=()
while IFS=$'\t' read -r name status expiry can_renew; do
    [[ -z "$name" ]] && continue
    read -r days in_win is_perm <<<"$(calc_expiry "$expiry")"
    if [[ "$is_perm" == "yes" ]]; then
        echo "[跳过] $name 永久域名" >&2
        continue
    fi
    if [[ "$in_win" != "yes" ]]; then
        echo "[窗口外] $name 剩余 ${days} 天 (到期 ${expiry})" >&2
        continue
    fi
    case "$(tr '[:upper:]' '[:lower:]' <<<"${can_renew}")" in
        false|0|no) echo "[不可续] $name can_renew=${can_renew}" >&2; continue ;;
    esac
    echo "[待续期] $name 剩余 ${days} 天 (到期 ${expiry})" >&2
    renew_targets+=("$name")
done <<<"$raw_tsv"

echo "===== 阶段 2: 自动续期 =====" >&2
declare -a renewed=() failed=()
if (( ${#renew_targets[@]} == 0 )); then
    echo "无进入续期窗口的域名" >&2
else
    for name in "${renew_targets[@]}"; do
        if [[ "$DRY_RUN" == "1" ]]; then
            echo "[DRY-RUN] 将续期 $name" >&2
            continue
        fi
        body=$(printf '{"renewal_type":"%s","years":%s}' "$RENEWAL_TYPE" "$RENEWAL_YEARS")
        if resp=$(python3 "$HELPER" "/domains/${name}/renew" "Bearer ${API_KEY}" \
                --method POST --body "$body" 2>&1); then
            if jq -e '.success == false' <<<"$resp" >/dev/null 2>&1; then
                msg=$(jq -r '.error // .message // "unknown"' <<<"$resp" 2>/dev/null || echo "$resp")
                echo "[失败] $name -> $msg" >&2
                failed+=("${name}:${msg}")
            else
                echo "[成功] $name 已续期" >&2
                renewed+=("$name")
            fi
        else
            echo "[失败] $name 请求异常" >&2
            failed+=("${name}:request-error")
        fi
    done
fi

echo "===== 阶段 3: 重新读取权威状态 =====" >&2
final_tsv=$(fetch_domains) || final_tsv="$raw_tsv"

# ===== 构建 Telegram 通知 =====
notification_lines=()
notification_lines+=("<b>DigitalPlat 域名状态</b>")
notification_lines+=("")

total=0
in_final_window=0

while IFS=$'\t' read -r name status expiry can_renew; do
    [[ -z "$name" ]] && continue
    ((total++)) || true

    read -r days in_win is_perm <<<"$(calc_expiry "$expiry")"

    if [[ "$is_perm" == "yes" ]]; then
        notification_lines+=("♾️ <code>${name}</code> — 永久")
        continue
    fi

    was_renewed=""
    for r in "${renewed[@]:-}"; do
        [[ "$r" == "$name" ]] && { was_renewed="1"; break; }
    done

    if [[ -n "$was_renewed" ]]; then
        notification_lines+=("✅ <code>${name}</code> — ${expiry} (剩 ${days} 天) | 已自动续期")
    elif (( days < 0 )); then
        notification_lines+=("❌ <code>${name}</code> — ${expiry} | 已过期 $(( -days )) 天")
    elif (( days <= RENEWAL_WINDOW_DAYS )); then
        ((in_final_window++)) || true
        notification_lines+=("⚠️ <code>${name}</code> — ${expiry} (剩 ${days} 天) | 窗口内")
    else
        notification_lines+=("🟢 <code>${name}</code> — ${expiry} (剩 ${days} 天)")
    fi
done <<<"$final_tsv"

notification_lines+=("")
notification_lines+=("📊 共 ${total} 个域名 | 窗口内 ${in_final_window} 个")

if (( ${#renewed[@]} > 0 )); then
    notification_lines+=("")
    notification_lines+=("🟢 本次已自动续期 ${#renewed[@]} 个: $(IFS=,; echo "${renewed[*]}")")
fi
if (( ${#failed[@]} > 0 )); then
    notification_lines+=("")
    notification_lines+=("🔴 续期失败 ${#failed[@]} 个: $(IFS=,; echo "${failed[*]}")")
fi
if (( ${#renewed[@]} == 0 && ${#failed[@]} == 0 )); then
    notification_lines+=("")
    notification_lines+=("✅ 本次无需续期")
fi

send_telegram() {
    local msg="$1"
    curl --fail-with-body --silent --show-error \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=${msg}" \
        --data-urlencode "disable_web_page_preview=true" >/dev/null
}

message=""
for line in "${notification_lines[@]}"; do
    if (( ${#message} + ${#line} + 1 > 3800 )); then
        send_telegram "$message"
        message='<b>DigitalPlat 域名状态（续）</b>'
    fi
    if [[ -z "$message" ]]; then
        message="$line"
    else
        message+=$'\n'"$line"
    fi
done
if [[ -n "$message" ]]; then
    send_telegram "$message"
fi

echo "通知已发送" >&2