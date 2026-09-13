#!/bin/sh
# ============================================================================
# usx-campus-auth —— 通用校园网 Web 门户自动认证脚本
#
# 用途：路由器/主机定时探测是否已掉线，掉线就自动重发一次门户认证请求。
# 注意：这是【通用模板】——脚本零凭据，必须照 README 填好配置文件才会生效。
#       也不是 LuCI 插件，没有网页界面，就是脚本 + 配置 + crontab。
# 适用：任何「浏览器里填账号密码登录、靠 HTTP(S) 请求完成认证」的校园网门户
#       （Dr.COM eportal、城市热点、深澜、锐捷 Web 版等形状都可套）。
#       不是协议逆向，只是把你在浏览器里发过的那个请求，原样用 curl 重放。
#
# 依赖：curl（必需）、ca-certificates（https 探针必需）
#       OpenWrt: apk add curl ca-certificates    # 24.10+ 用 apk
#                旧版: opkg update && opkg install curl ca-certificates
#
# 配置：所有学校相关信息都放在【外部配置文件】里，默认 /etc/campus_auth.conf
#       脚本本身不含任何账号密码，可以安全上传 GitHub。
#       复制 campus_auth.conf.example 改一份即可。
#
# 用法：
#   ./campus_auth.sh                 # 跑一次（在线就静默退出）
#   ./campus_auth.sh -v              # 详细输出（首次调试必用）
#   ./campus_auth.sh -d              # 前台常驻循环（调试用，别和 cron 同时开）
#   ./campus_auth.sh -c /path/to.conf
#   ./campus_auth.sh --show-config   # 打印渲染后的请求（密码打码），不发请求
#   ./campus_auth.sh --print-cron    # 打印推荐的 crontab 行
#   ./campus_auth.sh -h              # 帮助
#
# 定时（以每 5 分钟为例，写入 /etc/crontabs/root）：
#   0,5,10,15,20,25,30,35,40,45,50,55 * * * * /etc/campus_auth.sh >/dev/null 2>&1
#
# 许可：MIT。详见 LICENSE。
# ============================================================================

set -u

# ---------------------------------------------------------------------------
# 默认配置（全部为空；真正的值来自配置文件）
# ---------------------------------------------------------------------------
CONF_FILE="${CAMPUS_AUTH_CONF:-/etc/campus_auth.conf}"

SERVER=""            # 认证服务器主机，如 172.19.254.1
PORT=""              # 端口，如 801；无端口留空
AUTH_PATH=""         # 请求路径，如 /eportal/portal/login
AUTH_METHOD="GET"    # GET 或 POST
AUTH_QUERY=""        # 参数体（占位符见下）
USER_ACCOUNT=""      # 账号（明文，脚本负责 URL 编码）
USER_PASSWORD=""     # 密码（明文）
IP_PREFIX=""         # 校园网内网 IP 网段前缀，如 172.19.
IFACE=""             # 可选：指定取 IP 的网卡，留空则自动挑
REFERER=""           # 可选：Referer 头
PROBE_URL="https://www.baidu.com"
PROBE_CA="strict"    # strict | auto | insecure
FAIL_THRESHOLD=3
INTERVAL=60
SUCCESS_PATTERN='"result":[ ]*1[},]|"result":[ ]*"1"[},]|successlogin|已经成功登录'
LOG_TAG="campus_auth"

# AUTH_QUERY 支持的占位符（运行时替换）：
#   +USER+  账号（URL 编码后）
#   +PASS+  密码（URL 编码后）
#   +IP+    当前校园网内网 IP
#   +MAC+   出口网卡 MAC（冒号形式，如 14:a1:df:ba:f1:89）
#   +TS+    Unix 时间戳（秒）
#   +TSMS+  毫秒时间戳

# ---------------------------------------------------------------------------
# 命令行参数
# ---------------------------------------------------------------------------
VERBOSE=0
DAEMON=0
SHOW_CONFIG=0

while [ $# -gt 0 ]; do
    case "$1" in
        -v|--verbose)   VERBOSE=1 ;;
        -d|--daemon)    DAEMON=1 ;;
        -h|--help)      sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -c|--conf)      shift; [ $# -gt 0 ] && CONF_FILE="$1" ;;
        --show-config)  SHOW_CONFIG=1; VERBOSE=1 ;;
        --print-cron)   echo "0,5,10,15,20,25,30,35,40,45,50,55 * * * * $(readlink -f "$0" 2>/dev/null || echo /etc/campus_auth.sh) >/dev/null 2>&1"; exit 0 ;;
        *) echo "未知参数: $1（用 -h 看帮助）" >&2; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------
log() {
    # 无 syslog 的环境（如本机调试）只回显，不报错
    if command -v logger >/dev/null 2>&1; then
        logger -t "$LOG_TAG" "$1"
    fi
    [ "$VERBOSE" = "1" ] && echo "[${LOG_TAG}] $1"
    return 0
}

die() {
    echo "[${LOG_TAG}] ERROR: $1" >&2
    command -v logger >/dev/null 2>&1 && logger -t "$LOG_TAG" "ERROR: $1"
    exit "${2:-1}"
}

# ---------------------------------------------------------------------------
# 加载配置文件
# ---------------------------------------------------------------------------
[ -f "$CONF_FILE" ] || die "找不到配置文件：$CONF_FILE
  复制一份示例改：cp campus_auth.conf.example /etc/campus_auth.conf
  或用 -c 指定路径"

# shellcheck disable=SC1090
. "$CONF_FILE"

# 必填校验：早失败，别让它变成"每次都认证失败"的怪现象
[ -n "$SERVER" ]      || die "SERVER 为空：填认证服务器主机"
[ -n "$AUTH_PATH" ]   || die "AUTH_PATH 为空：填认证请求路径（如 /eportal/portal/login）"
[ -n "$AUTH_QUERY" ]  || die "AUTH_QUERY 为空：填浏览器抓到的参数体"
[ -n "$USER_ACCOUNT" ] || die "USER_ACCOUNT 为空"
[ -n "$USER_PASSWORD" ] || die "USER_PASSWORD 为空"
case "$AUTH_METHOD" in
    GET|POST) ;;
    *) die "AUTH_METHOD 只能是 GET 或 POST（当前：$AUTH_METHOD）" ;;
esac

command -v curl >/dev/null 2>&1 \
    || die "找不到 curl。OpenWrt: apk add curl ca-certificates（Debian/Ubuntu: apt install curl ca-certificates）" 127

# ---------------------------------------------------------------------------
# 取 IP / MAC
# ---------------------------------------------------------------------------
wan_iface() {
    ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

iface_ip() {
    ip -4 addr show dev "$1" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1
}

iface_mac() {
    ip link show dev "$1" 2>/dev/null | awk '/ether/{print $2; exit}'
}

# 校园网内网 IP：优先指定网卡 → 其次网段前缀 → 最后排除私有网段后的第一个
get_ip() {
    if [ -n "$IFACE" ]; then
        iface_ip "$IFACE"
        return
    fi
    ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | while read -r a; do
        case "$a" in
            127.*|192.168.*|10.*|169.254.*|172.17.*) continue ;;
        esac
        if [ -n "$IP_PREFIX" ]; then
            case "$a" in
                ${IP_PREFIX}*) echo "$a"; break ;;
            esac
        else
            echo "$a"; break
        fi
    done
}

# ---------------------------------------------------------------------------
# URL 编码（只编码「值」，不破坏参数里的 = 和 &）
# ---------------------------------------------------------------------------
urlencode() {
    printf '%s' "$1" | sed \
        -e 's/%/%25/g' -e 's/&/%26/g' -e 's/ /%20/g' -e 's/!/%21/g' \
        -e 's/"/%22/g' -e 's/#/%23/g' -e 's/\$/%24/g' -e "s/'/%27/g" \
        -e 's/(/%28/g' -e 's/)/%29/g' -e 's/\*/%2A/g' -e 's/+/%2B/g' \
        -e 's/,/%2C/g' -e 's/:/%3A/g' -e 's/;/%3B/g' -e 's/</%3C/g' \
        -e 's/=/%3D/g' -e 's/>/%3E/g' -e 's/?/%3F/g' -e 's/@/%40/g' \
        -e 's|/|%2F|g' \
        -e 's/\[/%5B/g' -e 's/\\/%5C/g' -e 's/\]/%5D/g' -e 's/\^/%5E/g' \
        -e 's/`/%60/g' -e 's/{/%7B/g' -e 's/|/%7C/g' -e 's/}/%7D/g'
}

# ---------------------------------------------------------------------------
# 占位符渲染
# ---------------------------------------------------------------------------
render() {
    s="$1"
    ts=$(date +%s)
    tsms=$(date +%s%3N 2>/dev/null)
    case "$tsms" in
        *N*|"") tsms="${ts}000" ;;
    esac

    e_user=$(urlencode "$USER_ACCOUNT")
    # 有第二个参数 = 只渲染「给人看」的那一份：原样放进密码位、不做编码（用于打码）
    if [ "$#" -ge 2 ]; then
        e_pass="$2"
    else
        e_pass=$(urlencode "$USER_PASSWORD")
    fi
    e_ip="$IP_NOW"
    e_mac="$MAC_NOW"

    s=$(printf '%s' "$s" | sed \
        -e "s|+USER+|${e_user}|g" \
        -e "s|+PASS+|${e_pass}|g" \
        -e "s|+IP+|${e_ip}|g" \
        -e "s|+MAC+|${e_mac}|g" \
        -e "s|+TSMS+|${tsms}|g" \
        -e "s|+TS+|${ts}|g")
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# 在线探测
# ---------------------------------------------------------------------------
# ⚠️ 必须用 https：明文 http 未认证时会被门户/网关代答 200 或 302，
#    拿到响应也分不清"真在线"和"被劫持"。https + 证书校验只有真在线才通过。
# ⚠️ 用全局变量而不是 $(...) 接返回值：命令替换开子 shell，
#    里面 PROBE_CA 的降级赋值会随子 shell 消失，降级永远不生效。
https_probe() {
    case "$PROBE_CA" in
        insecure)
            PROBE_CODE=$(curl -ks -o /dev/null -w '%{http_code}' -m 8 "$PROBE_URL" 2>/dev/null)
            return ;;
        strict)
            PROBE_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$PROBE_URL" 2>/dev/null)
            return ;;
    esac

    # auto（不推荐）：strict 不通再试 -k 兜底
    PROBE_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$PROBE_URL" 2>/dev/null)
    [ "$PROBE_CODE" = "200" ] && return

    code2=$(curl -ks -o /dev/null -w '%{http_code}' -m 8 "$PROBE_URL" 2>/dev/null)
    if [ "$code2" = "200" ]; then
        PROBE_CA="insecure"
        log "WARN: auto 模式 strict 不通但 -k 通（可能缺 CA，也可能是网关 SSL 中间人，两者无法区分），本轮起按不校验证书处理。正解：apt/apk add ca-certificates 并把 PROBE_CA 改回 strict"
        PROBE_CODE="$code2"
    fi
}

is_online() {
    https_probe
    [ "$PROBE_CODE" = "200" ]
}

# 连续 N 次都不通才认定真断线（去抖：DNS/网关瞬时抖一下不至于立刻发认证）
is_offline_confirmed() {
    i=1
    while [ "$i" -le "$FAIL_THRESHOLD" ]; do
        if is_online; then
            [ "$VERBOSE" = "1" ] && log "探测 $i/$FAIL_THRESHOLD：在线"
            return 1
        fi
        [ "$VERBOSE" = "1" ] && log "探测 $i/$FAIL_THRESHOLD：不通"
        i=$((i + 1))
        [ "$i" -le "$FAIL_THRESHOLD" ] && sleep 3
    done
    return 0
}

# ---------------------------------------------------------------------------
# 发一次认证
# ---------------------------------------------------------------------------
do_login() {
    IP_NOW=$(get_ip)
    [ -n "$IP_NOW" ] || { log "取不到校园网内网 IP，跳过（检查 IP_PREFIX / IFACE 配置）"; return 1; }

    host="http://${SERVER}"
    [ -n "$PORT" ] && host="${host}:${PORT}"

    body=$(render "$AUTH_QUERY")
    masked=$(render "$AUTH_QUERY" "****")

    ua='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

    # 可选请求头走位置参数：值里带空格也不会被拆成两个 curl 参数
    set -- -H 'Accept: */*' -H "User-Agent: $ua"
    [ -n "$REFERER" ] && set -- "$@" -H "Referer: ${REFERER}"

    if [ "$AUTH_METHOD" = "POST" ]; then
        url="${host}${AUTH_PATH}"
        URL_DISPLAY="${url}?${masked}"
        resp=$(curl -s -m 10 -X POST "$url" \
            -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
            "$@" --data-raw "$body" 2>/dev/null)
    else
        url="${host}${AUTH_PATH}?${body}"
        URL_DISPLAY="${host}${AUTH_PATH}?${masked}"
        resp=$(curl -s -m 10 "$url" "$@" 2>/dev/null)
    fi

    [ "$VERBOSE" = "1" ] && {
        log "IP=${IP_NOW} MAC=${MAC_NOW} METHOD=${AUTH_METHOD}"
        log "URL=${URL_DISPLAY}"
        log "响应: $(printf '%s' "$resp" | head -c 400)"
    }

    if printf '%s' "$resp" | grep -qE "$SUCCESS_PATTERN"; then
        log "认证成功 (IP=${IP_NOW})"
        return 0
    fi

    case "$resp" in
        *"已经在线"*|*"已在线"*|*"注销"*)
            log "已在线（无需重复认证）"; return 0 ;;
        *"超过"*|*"设备数"*|*"数量"*|*"limit"*|*"Limit"*)
            log "WARN: 疑似设备数达上限 —— 先让其他设备下线，稍后自动重试"; return 2 ;;
        "")
            log "认证请求无响应 —— 检查 SERVER / PORT / AUTH_PATH"; return 1 ;;
        *)
            log "认证失败，原始响应: $(printf '%s' "$resp" | head -c 300)"; return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
IP_NOW=""
MAC_NOW=""
WIFACE=$(wan_iface)
[ -n "$IFACE" ] && WIFACE="$IFACE"
[ -n "$WIFACE" ] && MAC_NOW=$(iface_mac "$WIFACE")
[ -z "$MAC_NOW" ] && MAC_NOW="000000000000"

if [ "$SHOW_CONFIG" = "1" ]; then
    IP_NOW=$(get_ip)
    echo "配置文件 : $CONF_FILE"
    echo "出口网卡 : ${WIFACE:-未识别}"
    echo "内网 IP  : ${IP_NOW:-未识别}"
    echo "MAC      : $MAC_NOW"
    echo "请求方式 : $AUTH_METHOD"
    echo "请求 URL : http://${SERVER}${PORT:+:${PORT}}${AUTH_PATH}?$(render "$AUTH_QUERY" "****")"
    exit 0
fi

run_once() {
    if ! is_offline_confirmed; then
        [ "$VERBOSE" = "1" ] && log "在线，无需操作"
        return 0
    fi
    log "连续 ${FAIL_THRESHOLD} 次探测不通，触发重认证"
    do_login
}

if [ "$DAEMON" = "1" ]; then
    log "常驻模式启动，间隔 ${INTERVAL}s"
    while true; do
        run_once
        sleep "$INTERVAL"
    done
else
    run_once
fi
