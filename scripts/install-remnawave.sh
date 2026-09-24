#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Remnawave cascade installer — один файл, две роли (для RuVDS и любых
# Debian/Ubuntu VPS)
#
# ROLE=ru — превращает VPS в России (с "белым" IP) во ВХОДНУЮ ноду
# каскада. Клиент -> эта нода -> зарубежная (EU) нода -> Internet.
#
#   Client / HAPP
#       |  TCP :443  VLESS Reality (SNI из белого списка или self-steal)
#       v
#   RU-нода (этот сервер, Remnawave Node)
#       |-- RU-сайты / RU-IP ----> напрямую (DIRECT)     [шаблон маршрутов 1]
#       '-- всё остальное -------> EU-нода (VLESS Reality outbound)
#
# ROLE=eu — превращает VPS в ВЫХОДНУЮ ноду каскада (или просто
# self-steal-сервер сам по себе): self-steal на своём домене, выход в
# интернет через Cloudflare WARP (или DIRECT, если WARP не нужен).
# Ей понадобится сервисный пользователь — его vless://-ссылку вставляют
# при установке RU-ноды.
#
#   [RU-нода] -> TCP :443  VLESS Reality (self-steal)
#       v
#   EU-нода (этот сервер, Remnawave Node)
#       '-- WARP или DIRECT -------> Internet
#
# Шаблоны:
#   * маскировка входа (ROLE=ru) : SNI из белого списка (ya.ru/vk.com/ozon.ru/
#                                   свой) или self-steal на своём домене
#   * decoy-сайт (self-steal)    : 7 шаблонов, от лендинга IT-студии до
#                                   status page
#   * маршруты (ROLE=ru)         : 1) RU напрямую, остальное в EU  2) всё в EU
#
# Без вопросов (все параметры через переменные окружения) — см. --help.
# ============================================================

export DEBIAN_FRONTEND=noninteractive

SCRIPT_NAME="install-remnawave.sh"
SCRIPT_VERSION="2.0.0"

# Откуда брать обновления. Задайте своими значениями (или через переменные
# окружения GH_REPO/GH_BRANCH/GH_TOKEN при запуске).
GH_REPO="${GH_REPO:-Hellon048/PremiumHostingScript}"
GH_BRANCH="${GH_BRANCH:-main}"
GH_TOKEN="${GH_TOKEN:-}"
UPDATE_CHECK="${UPDATE_CHECK:-1}"

WORK="${WORK:-/root/remna-bridge-build}"
NODE_DIR="${NODE_DIR:-/opt/remnanode}"
DECOY_ROOT="${DECOY_ROOT:-/var/www/remna-self-steal}"
SELF_PORT="${SELF_PORT:-8081}"
VLESS_PORT="${VLESS_PORT:-443}"
TEST_PORT="${TEST_PORT:-10809}"
WARP_TEST_PORT="${WARP_TEST_PORT:-10808}"
NODE_IMAGE="${NODE_IMAGE:-remnawave/node:latest}"
NODE_IMAGE_GHCR="ghcr.io/remnawave/node:latest"
ENTRY_TAG="VLESS_RU_ENTRY"
TOOL="$WORK/bridge_tool.py"
CONTAINER_NAME="${CONTAINER_NAME:-}"

# Значения, которые можно задать заранее через окружение
ROLE="${ROLE:-}"
NODE_SECRET="${NODE_SECRET:-}"
NODE_PORT="${NODE_PORT:-}"
ENTRY_MODE="${ENTRY_MODE:-}"
REALITY_SNI="${REALITY_SNI:-}"
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
DECOY_TEMPLATE="${DECOY_TEMPLATE:-}"
EU_LINK="${EU_LINK:-}"
ROUTE_TEMPLATE="${ROUTE_TEMPLATE:-}"
EXTRA_DIRECT="${EXTRA_DIRECT:-}"
WARP_ENABLED="${WARP_ENABLED:-}"
USE_SELFSTEAL="${USE_SELFSTEAL:-0}"

# Внутреннее состояние
REALITY_TARGET=""
REALITY_PRIVATE=""
REALITY_PUBLIC=""
SHORT_ID_1=""
SHORT_ID_2=""
SERVER_IP=""
LINK_JSON="$WORK/eu-link.json"
USED_VARIANT=""
EU_EXIT_IP=""
EU_LOC=""
EU_WARP=""
IS_TTY=0
[[ -t 0 ]] && IS_TTY=1
ORIG_ARGS=("$@")

mkdir -p "$WORK"
chmod 700 "$WORK"

green()  { echo -e "\033[32m[OK]\033[0m $*"; }
blue()   { echo -e "\033[36m[INFO]\033[0m $*"; }
yellow() { echo -e "\033[33m[WARN]\033[0m $*"; }
red()    { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

die() {
    red "$*"
    exit 1
}

print_usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}
Ставит одну из двух ролей каскада Remnawave (Docker + Reality):
  ROLE=ru — RU-вход: white-list SNI или self-steal, outbound на EU-ноду
  ROLE=eu — EU-выход: self-steal + Cloudflare WARP (или просто DIRECT)

Использование:
  bash ${SCRIPT_NAME}                запуск с вопросами по ходу дела
  bash ${SCRIPT_NAME} --help         это сообщение
  bash ${SCRIPT_NAME} --version      показать версию
  bash ${SCRIPT_NAME} --no-update    не проверять обновления в этом запуске

Общие параметры (обе роли):
  ROLE              ru | eu                                     (иначе спросит)
  NODE_SECRET       SECRET_KEY ноды из панели Remnawave        (обязателен)
  NODE_PORT         Node API port                              (по умолч. 2222)
  CONTAINER_NAME    имя контейнера/образа ноды                 (по умолч. спросит)

Параметры ROLE=ru:
  ENTRY_MODE        1-5, шаблон маскировки входа
                       1=ya.ru 2=vk.com 3=ozon.ru 4=свой SNI 5=self-steal
  REALITY_SNI       SNI для режимов 1-4
  EU_LINK           vless://-ссылка сервисного пользователя EU-ноды (обязателен)
  ROUTE_TEMPLATE    1 (RU напрямую/остальное в EU) или 2 (всё в EU)
  EXTRA_DIRECT      доп. домены напрямую через RU, через запятую

Параметры ROLE=eu:
  WARP_ENABLED      1 (через Cloudflare WARP, по умолч.) или 0 (DIRECT)

Общие для self-steal (ROLE=ru ENTRY_MODE=5, или любой ROLE=eu):
  DOMAIN, EMAIL     домен и email для Let's Encrypt              (обязательны)
  DECOY_TEMPLATE    1-7, шаблон decoy-сайта

Обновления:
  GH_REPO           владелец/репозиторий на GitHub (по умолч. в коде скрипта)
  GH_BRANCH         ветка                                       (по умолч. main)
  GH_TOKEN          токен доступа, нужен для приватного репозитория
  UPDATE_CHECK=0    отключить проверку обновлений

Пример неинтерактивного запуска (RU):
  ROLE=ru NODE_SECRET='...' NODE_PORT=2222 CONTAINER_NAME=cache-worker \\
  ENTRY_MODE=1 EU_LINK='vless://...' ROUTE_TEMPLATE=1 \\
  bash ${SCRIPT_NAME}

Пример неинтерактивного запуска (EU):
  ROLE=eu NODE_SECRET='...' NODE_PORT=2222 CONTAINER_NAME=media-sync \\
  DOMAIN=vpn.example.com EMAIL=me@example.com DECOY_TEMPLATE=3 WARP_ENABLED=1 \\
  bash ${SCRIPT_NAME}
EOF
}

check_for_update() {
    [[ "$UPDATE_CHECK" == "1" ]] || return 0
    [[ "$GH_REPO" != *YOUR_GITHUB_LOGIN* ]] || return 0
    command -v curl >/dev/null 2>&1 || return 0

    local raw_url="https://raw.githubusercontent.com/${GH_REPO}/${GH_BRANCH}/scripts/${SCRIPT_NAME}"
    local -a curl_auth=()
    [[ -n "$GH_TOKEN" ]] && curl_auth=(-H "Authorization: token ${GH_TOKEN}")

    local remote_file="$WORK/remote-script.sh"
    if ! curl -fsSL --max-time 8 "${curl_auth[@]}" "$raw_url" -o "$remote_file" 2>/dev/null; then
        return 0   # нет сети/репозитория ещё не существует — тихо продолжаем со своей версией
    fi

    local remote_version
    remote_version="$(grep -m1 '^SCRIPT_VERSION=' "$remote_file" | cut -d'"' -f2)"
    [[ -n "$remote_version" ]] || return 0

    if [[ "$remote_version" == "$SCRIPT_VERSION" ]]; then
        rm -f "$remote_file"
        return 0
    fi

    yellow "Доступна версия скрипта ${remote_version} (сейчас ${SCRIPT_VERSION})."
    if confirm "Обновиться и перезапустить?" y; then
        local target
        target="$(readlink -f -- "$0" 2>/dev/null || echo "$0")"
        if [[ -w "$target" || -w "$(dirname -- "$target")" ]]; then
            cp "$remote_file" "$target"
            chmod +x "$target"
            rm -f "$remote_file"
            green "Обновлено до ${remote_version}, перезапускаю..."
            exec bash "$target" "${ORIG_ARGS[@]}"
        else
            yellow "Нет прав на запись в ${target}, обновление пропущено."
        fi
    fi
    rm -f "$remote_file"
}

cleanup_test() {
    docker exec "$CONTAINER_NAME" sh -c '
      if [ -f /tmp/eu-test.pid ]; then
        kill "$(cat /tmp/eu-test.pid)" 2>/dev/null || true
      fi
      rm -f /tmp/eu-test.pid
    ' >/dev/null 2>&1 || true
}

on_error() {
    red "Сбой на строке $1: $2"
}

trap cleanup_test EXIT
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# ------------------------------------------------------------
# Ввод
# ------------------------------------------------------------

# ask VAR "Вопрос" [значение_по_умолчанию]
ask() {
    local __var="$1" __prompt="$2" __def="${3:-}" __val=""
    if [[ -n "${!__var:-}" ]]; then
        return 0
    fi
    if [[ -n "$__def" ]]; then
        read -r -p "$__prompt [$__def]: " __val || die "Нет ввода для $__var"
        __val="${__val:-$__def}"
    else
        read -r -p "$__prompt: " __val || die "Нет ввода для $__var"
    fi
    [[ -n "$__val" ]] || die "$__var обязателен."
    printf -v "$__var" '%s' "$__val"
}

# ask_opt VAR "Вопрос" — можно оставить пустым
ask_opt() {
    local __var="$1" __prompt="$2" __val=""
    if [[ -n "${!__var:-}" || "$IS_TTY" != "1" ]]; then
        return 0
    fi
    read -r -p "$__prompt: " __val || __val=""
    printf -v "$__var" '%s' "$__val"
}

# ask_choice VAR "Вопрос" по_умолчанию '^[1-5]$'
ask_choice() {
    local __var="$1" __prompt="$2" __def="$3" __re="$4" __val=""
    if [[ -n "${!__var:-}" ]]; then
        [[ "${!__var}" =~ $__re ]] || die "Некорректное значение ${__var}=${!__var}"
        return 0
    fi
    while true; do
        read -r -p "$__prompt [$__def]: " __val || die "Нет ввода для $__var"
        __val="${__val:-$__def}"
        if [[ "$__val" =~ $__re ]]; then
            printf -v "$__var" '%s' "$__val"
            return 0
        fi
        yellow "Неверный выбор, попробуй ещё раз."
    done
}

# confirm "Вопрос" y|n  (по умолчанию)
confirm() {
    local __def="${2:-y}" __ans="" __hint="Y/n"
    [[ "$__def" == "n" ]] && __hint="y/N"
    if [[ "$IS_TTY" != "1" ]]; then
        [[ "$__def" == "y" ]]
        return
    fi
    read -r -p "$1 [$__hint]: " __ans || __ans=""
    __ans="${__ans:-$__def}"
    [[ "${__ans,,}" == y* ]]
}

tool() {
    python3 "$TOOL" "$@"
}

port_listening() {
    local out
    out="$(ss -H -lnt 2>/dev/null || true)"
    grep -Eq "[:.]$1[[:space:]]" <<<"$out"
}

detect_server_ip() {
    SERVER_IP="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null |
            awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)"
    fi
}

# ------------------------------------------------------------
# Python-помощник (разбор vless://, сборка конфигов)
# ------------------------------------------------------------

write_tool() {
    cat > "$TOOL" <<'PYEOF'
#!/usr/bin/env python3
"""Helper for install-remnawave-ru-bridge.sh.

Parses a vless:// link of the exit (EU) node and builds Xray configs
for the RU entry node. Uses only the Python standard library.
"""
import argparse
import json
import sys
import uuid
from urllib.parse import parse_qs, unquote, urlsplit

RU_DOMAINS = ["geosite:category-ru", "domain:ru", "domain:su", "domain:xn--p1ai"]
DNS_SERVERS = ["77.88.8.8", "77.88.8.1", "1.1.1.1"]
EXIT_TAG = "TO_EU"


def die(msg):
    sys.stderr.write(str(msg) + "\n")
    sys.exit(1)


def load(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


# --------------------------------------------------------------------------
# vless:// link
# --------------------------------------------------------------------------
def parse_link(link):
    link = link.strip()
    if not link.lower().startswith("vless://"):
        die("ссылка должна начинаться с vless://")

    u = urlsplit(link)
    q = {k: v[0] for k, v in parse_qs(u.query, keep_blank_values=True).items()}

    uid = unquote(u.username or "")
    host = u.hostname
    try:
        port = u.port or 443
    except ValueError:
        die("некорректный порт в ссылке")

    if not uid or not host:
        die("в ссылке нет UUID или адреса сервера")

    security = q.get("security", "none").lower()
    if security != "reality":
        die("нужна ссылка с security=reality (в ссылке: %s)" % security)

    typ = q.get("type", "tcp").lower()
    if typ in ("tcp", "raw"):
        typ = "raw"
    elif typ != "xhttp":
        die("транспорт type=%s не поддерживается (нужен tcp/raw или xhttp)" % typ)

    pbk = q.get("pbk", "")
    sni = q.get("sni", "")
    if not pbk:
        die("в ссылке нет pbk (публичный ключ Reality)")
    if not sni:
        die("в ссылке нет sni")

    extra = None
    if q.get("extra"):
        try:
            extra = json.loads(q["extra"])
        except ValueError:
            extra = None

    return {
        "id": uid,
        "address": host,
        "port": port,
        "encryption": q.get("encryption", "none") or "none",
        "flow": q.get("flow", ""),
        "type": typ,
        "sni": sni,
        "pbk": pbk,
        "sid": q.get("sid", ""),
        "fp": q.get("fp", "chrome") or "chrome",
        "spx": q.get("spx", ""),
        "path": q.get("path", "/") or "/",
        "mode": q.get("mode", "auto") or "auto",
        "host": q.get("host", ""),
        "extra": extra,
    }


def variants(link):
    """Formats of the VLESS outbound to try, from most to least modern."""
    nets = ["raw", "tcp"] if link["type"] == "raw" else ["xhttp"]
    return ["%s:%s" % (fmt, net) for net in nets for fmt in ("flat", "vnext")]


def build_stream(link, net):
    if link["type"] == "xhttp":
        xs = {"path": link["path"], "mode": link["mode"]}
        if link["host"]:
            xs["host"] = link["host"]
        if link["extra"]:
            xs["extra"] = link["extra"]
        stream = {"network": "xhttp", "xhttpSettings": xs}
    else:
        stream = {"network": net}

    stream["security"] = "reality"
    stream["realitySettings"] = {
        "serverName": link["sni"],
        "fingerprint": link["fp"],
        "publicKey": link["pbk"],
        "shortId": link["sid"],
        "spiderX": link["spx"],
    }
    return stream


def build_outbound(link, fmt, net):
    user = {"id": link["id"], "encryption": link["encryption"], "level": 0}
    if link["flow"]:
        user["flow"] = link["flow"]

    if fmt == "vnext":
        settings = {
            "vnext": [
                {"address": link["address"], "port": link["port"], "users": [user]}
            ]
        }
    elif fmt == "flat":
        settings = {"address": link["address"], "port": link["port"]}
        settings.update(user)
    else:
        die("неизвестный формат outbound: %s" % fmt)

    return {
        "tag": EXIT_TAG,
        "protocol": "vless",
        "settings": settings,
        "streamSettings": build_stream(link, net),
    }


# --------------------------------------------------------------------------
# configs
# --------------------------------------------------------------------------
def build_test_config(outbound, port):
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {
                "tag": "EU_TEST",
                "listen": "127.0.0.1",
                "port": port,
                "protocol": "http",
                "settings": {},
            }
        ],
        "outbounds": [outbound],
        "routing": {
            "rules": [{"inboundTag": ["EU_TEST"], "outboundTag": outbound["tag"]}]
        },
    }


def parse_extra_domains(raw):
    out = []
    for item in (raw or "").split(","):
        item = item.strip()
        if not item:
            continue
        out.append(item if ":" in item else "domain:" + item)
    return out


def build_final(a):
    outbound = load(a.outbound)
    clients = []
    if a.test_client:
        clients = [{"id": str(uuid.uuid4()), "flow": "xtls-rprx-vision"}]

    rules = [
        {"ip": ["geoip:private"], "outboundTag": "BLOCK"},
        {"domain": ["geosite:private"], "outboundTag": "BLOCK"},
        {"protocol": ["bittorrent"], "outboundTag": "BLOCK"},
    ]

    if a.split == "1":
        extras = parse_extra_domains(a.extra)
        if extras:
            rules.append({"domain": extras, "outboundTag": "DIRECT"})
        rules.append({"domain": RU_DOMAINS, "outboundTag": "DIRECT"})
        rules.append({"ip": ["geoip:ru"], "outboundTag": "DIRECT"})

    rules.append({"inboundTag": [a.tag], "outboundTag": outbound["tag"]})

    return {
        "log": {"loglevel": "none"},
        "dns": {"servers": DNS_SERVERS, "queryStrategy": "UseIPv4"},
        "inbounds": [
            {
                "tag": a.tag,
                "port": a.port,
                "listen": "0.0.0.0",
                "protocol": "vless",
                "settings": {"clients": clients, "decryption": "none"},
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls", "quic"],
                },
                "streamSettings": {
                    "network": "raw",
                    "security": "reality",
                    "realitySettings": {
                        "show": False,
                        "target": a.target,
                        "spiderX": "",
                        "shortIds": [a.sid1, a.sid2],
                        "privateKey": a.private,
                        "serverNames": [a.sni],
                    },
                },
            }
        ],
        "outbounds": [
            outbound,
            {"tag": "DIRECT", "protocol": "freedom"},
            {"tag": "BLOCK", "protocol": "blackhole"},
        ],
        "routing": {"rules": rules},
    }


def build_final_eu(a):
    outbound = load(a.outbound)
    clients = []
    if a.test_client:
        clients = [{"id": str(uuid.uuid4()), "flow": "xtls-rprx-vision"}]

    dns_servers = [x.strip() for x in a.dns.split(",") if x.strip()]

    rules = [
        {"ip": ["geoip:private"], "outboundTag": "BLOCK"},
        {"domain": ["geosite:private"], "outboundTag": "BLOCK"},
        {"protocol": ["bittorrent"], "outboundTag": "BLOCK"},
        {"inboundTag": [a.tag], "outboundTag": outbound["tag"]},
    ]

    reality_settings = {
        "target": a.target,
        "spiderX": "",
        "shortIds": [a.sid1, a.sid2],
        "privateKey": a.private,
        "serverNames": [a.sni],
    }
    if a.fingerprint:
        reality_settings["fingerprint"] = a.fingerprint
        reality_settings["minClientVer"] = "0.0.0"

    outbounds = [outbound]
    tags_present = {outbound["tag"]}
    if "DIRECT" not in tags_present:
        outbounds.append({"tag": "DIRECT", "protocol": "freedom"})
    outbounds.append({"tag": "BLOCK", "protocol": "blackhole"})

    return {
        "log": {"loglevel": "none"},
        "dns": {"servers": dns_servers, "queryStrategy": "UseIPv4"},
        "inbounds": [
            {
                "tag": a.tag,
                "port": a.port,
                "listen": "0.0.0.0",
                "protocol": "vless",
                "settings": {"clients": clients, "decryption": "none"},
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls", "quic"],
                },
                "streamSettings": {
                    "network": "raw",
                    "security": "reality",
                    "realitySettings": reality_settings,
                },
            }
        ],
        "outbounds": outbounds,
        "routing": {"rules": rules},
    }


def warp_adapt(a):
    cfg = load(a.file)
    cfg["tag"] = "WARP"
    cfg.setdefault("settings", {})
    cfg["settings"]["domainStrategy"] = "ForceIPv4"
    cfg["settings"]["noKernelTun"] = True
    peers = cfg["settings"].get("peers") or []
    if not peers:
        die("в wgcf xray-конфиге нет peers[]")
    peers[0]["endpoint"] = a.endpoint
    return cfg


def checkwarp(cfg):
    problems = []
    settings = cfg.get("settings", {})
    if not isinstance(settings.get("secretKey"), str) or not settings["secretKey"]:
        problems.append("secretKey отсутствует")
    peers = settings.get("peers") or []
    if not peers or not isinstance(peers[0].get("publicKey"), str) or not peers[0]["publicKey"]:
        problems.append("peers[0].publicKey отсутствует")
    reserved = settings.get("reserved")
    if not isinstance(reserved, list) or len(reserved) != 3:
        problems.append("reserved[] отсутствует или некорректен")
    return problems


def ghasset(release_json_text, asset_name):
    data = json.loads(release_json_text)
    for asset in data.get("assets", []):
        if asset.get("name") == asset_name:
            return asset.get("browser_download_url")
    return None


def check_final(cfg, a):
    problems = []
    inbound = next((i for i in cfg.get("inbounds", []) if i.get("tag") == a.tag), None)
    if inbound is None:
        problems.append("нет inbound с тегом %s" % a.tag)
    else:
        if inbound.get("port") != a.port:
            problems.append("inbound не на порту %s" % a.port)
        rs = inbound["streamSettings"]["realitySettings"]
        if rs.get("target") != a.target:
            problems.append("target не совпадает с ожидаемым (%s)" % a.target)
        if not rs.get("privateKey"):
            problems.append("пустой privateKey")
        if not rs.get("shortIds"):
            problems.append("пустые shortIds")
        if a.sni not in rs.get("serverNames", []):
            problems.append("serverNames не содержит %s" % a.sni)

    # Тег outbound'а, в который должен уйти трафик: для RU это "TO_EU"
    # (константа), для EU передаётся --outbound файлом (WARP или DIRECT).
    exit_tag = EXIT_TAG
    if getattr(a, "outbound", None):
        exit_tag = load(a.outbound)["tag"]

    tags = [o.get("tag") for o in cfg.get("outbounds", [])]
    required = {exit_tag, "BLOCK"}
    if exit_tag != "DIRECT":
        required.add("DIRECT")
    for need in required:
        if need not in tags:
            problems.append("нет outbound %s" % need)

    rules = cfg.get("routing", {}).get("rules", [])
    last = rules[-1] if rules else {}
    if last.get("inboundTag") != [a.tag] or last.get("outboundTag") != exit_tag:
        problems.append("последнее правило должно отправлять inbound в %s" % exit_tag)

    return problems


def hide_secrets(cfg):
    for ib in cfg.get("inbounds", []):
        rs = ib.get("streamSettings", {}).get("realitySettings", {})
        if "privateKey" in rs:
            rs["privateKey"] = "HIDDEN"
    for ob in cfg.get("outbounds", []):
        st = ob.get("settings", {})
        if "id" in st:
            st["id"] = "HIDDEN"
        if "secretKey" in st:
            st["secretKey"] = "HIDDEN"
        for vn in st.get("vnext", []):
            for us in vn.get("users", []):
                us["id"] = "HIDDEN"
    return cfg


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("parse")
    s.add_argument("link")

    s = sub.add_parser("get")
    s.add_argument("file")
    s.add_argument("key")

    s = sub.add_parser("variants")
    s.add_argument("file")

    s = sub.add_parser("outbound")
    s.add_argument("file")
    s.add_argument("--fmt", required=True)
    s.add_argument("--net", default="raw")

    s = sub.add_parser("testconf")
    s.add_argument("outbound")
    s.add_argument("--port", type=int, required=True)

    s = sub.add_parser("final")
    s.add_argument("--outbound", required=True)
    s.add_argument("--tag", required=True)
    s.add_argument("--port", type=int, required=True)
    s.add_argument("--target", required=True)
    s.add_argument("--sni", required=True)
    s.add_argument("--private", required=True)
    s.add_argument("--sid1", required=True)
    s.add_argument("--sid2", required=True)
    s.add_argument("--split", default="1")
    s.add_argument("--extra", default="")
    s.add_argument("--test-client", action="store_true")

    s = sub.add_parser("check")
    s.add_argument("file")
    s.add_argument("--tag", required=True)
    s.add_argument("--port", type=int, required=True)
    s.add_argument("--target", required=True)
    s.add_argument("--sni", required=True)
    s.add_argument("--outbound", default=None,
                    help="если задан, exit-тег берётся из этого outbound-файла "
                         "(для EU: WARP/DIRECT) вместо константы TO_EU")

    s = sub.add_parser("final_eu")
    s.add_argument("--outbound", required=True)
    s.add_argument("--tag", required=True)
    s.add_argument("--port", type=int, required=True)
    s.add_argument("--target", required=True)
    s.add_argument("--sni", required=True)
    s.add_argument("--private", required=True)
    s.add_argument("--sid1", required=True)
    s.add_argument("--sid2", required=True)
    s.add_argument("--dns", default="8.8.8.8,8.8.4.4")
    s.add_argument("--fingerprint", default="firefox")
    s.add_argument("--test-client", action="store_true")

    s = sub.add_parser("warpadapt")
    s.add_argument("file")
    s.add_argument("--endpoint", required=True)

    s = sub.add_parser("checkwarp")
    s.add_argument("file")

    s = sub.add_parser("ghasset")
    s.add_argument("--asset", required=True)

    s = sub.add_parser("show")
    s.add_argument("file")
    s.add_argument("--hide", action="store_true")

    a = p.parse_args()

    if a.cmd == "parse":
        print(json.dumps(parse_link(a.link)))
    elif a.cmd == "get":
        data = load(a.file)
        if a.key not in data:
            die("нет поля %s" % a.key)
        val = data[a.key]
        print(val if isinstance(val, str) else json.dumps(val))
    elif a.cmd == "variants":
        print("\n".join(variants(load(a.file))))
    elif a.cmd == "outbound":
        print(json.dumps(build_outbound(load(a.file), a.fmt, a.net), indent=2))
    elif a.cmd == "testconf":
        print(json.dumps(build_test_config(load(a.outbound), a.port), indent=2))
    elif a.cmd == "final":
        print(json.dumps(build_final(a), indent=2, ensure_ascii=False))
    elif a.cmd == "final_eu":
        print(json.dumps(build_final_eu(a), indent=2, ensure_ascii=False))
    elif a.cmd == "warpadapt":
        print(json.dumps(warp_adapt(a), indent=2, ensure_ascii=False))
    elif a.cmd == "checkwarp":
        problems = checkwarp(load(a.file))
        if problems:
            die("; ".join(problems))
    elif a.cmd == "ghasset":
        url = ghasset(sys.stdin.read(), a.asset)
        if not url:
            die("asset не найден: %s" % a.asset)
        print(url)
    elif a.cmd == "check":
        problems = check_final(load(a.file), a)
        if problems:
            die("; ".join(problems))
    elif a.cmd == "show":
        cfg = load(a.file)
        if a.hide:
            cfg = hide_secrets(cfg)
        print(json.dumps(cfg, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
PYEOF
    chmod 700 "$TOOL"
}

# ------------------------------------------------------------
# Шаблоны сайта-заглушки (режим self-steal)
# ------------------------------------------------------------

write_decoy_template() {
case "$DECOY_TEMPLATE" in
    1)
        blue "Шаблон: Весёлый кликер"
        cat > "$DECOY_ROOT/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="remna-decoy" content="ready">
<title>Click Lab</title>
<style>
*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;overflow:hidden;font-family:Inter,ui-rounded,system-ui,-apple-system,Segoe UI,sans-serif;background:radial-gradient(circle at 20% 20%,#ffe27a 0 10%,transparent 32%),radial-gradient(circle at 80% 12%,#ff8fcf 0 8%,transparent 30%),linear-gradient(135deg,#6c5ce7,#00cec9);color:#17172a}.card{width:min(92vw,680px);padding:34px;border-radius:32px;background:rgba(255,255,255,.9);box-shadow:0 30px 80px rgba(24,18,78,.28);text-align:center;backdrop-filter:blur(16px)}.badge{display:inline-block;padding:7px 12px;border-radius:999px;background:#17172a;color:#fff;font-size:12px;letter-spacing:.08em;text-transform:uppercase}h1{font-size:clamp(38px,8vw,72px);margin:18px 0 4px;line-height:1}p{margin:8px 0 24px;color:#606078}.score{font-size:clamp(52px,12vw,92px);font-weight:900;font-variant-numeric:tabular-nums}.click{appearance:none;border:0;width:190px;height:190px;border-radius:50%;font-size:29px;font-weight:900;color:#fff;cursor:pointer;background:linear-gradient(145deg,#ff7675,#e84393);box-shadow:0 18px 0 #ad2f69,0 28px 55px rgba(232,67,147,.35);transition:.08s transform,.08s box-shadow;user-select:none}.click:active,.click.hit{transform:translateY(14px) scale(.98);box-shadow:0 4px 0 #ad2f69,0 12px 28px rgba(232,67,147,.3)}.meta{display:flex;gap:12px;justify-content:center;flex-wrap:wrap;margin-top:28px}.pill{padding:10px 14px;background:#f1f2f6;border-radius:14px;color:#55556a;font-size:14px}.pop{position:fixed;pointer-events:none;font-weight:900;font-size:22px;animation:fly .7s ease-out forwards}@keyframes fly{to{transform:translateY(-95px) rotate(16deg) scale(1.4);opacity:0}}footer{margin-top:20px;color:#8b8ba0;font-size:12px}
</style>
</head>
<body>
<main class="card">
<span class="badge">tiny internet experiment</span>
<h1>Click Lab</h1>
<p>Highly scientific button. Absolutely serious research.</p>
<div class="score" id="score">0</div>
<button class="click" id="clicker" aria-label="Click">CLICK!</button>
<div class="meta"><div class="pill">Best: <b id="best">0</b></div><div class="pill">Level: <b id="level">1</b></div><div class="pill">Status: online</div></div>
<footer>${DOMAIN}</footer>
</main>
<script>
const b=document.getElementById('clicker'),s=document.getElementById('score'),best=document.getElementById('best'),level=document.getElementById('level');let n=0,r=Number(localStorage.getItem('click-best')||0);best.textContent=r;const words=['+1','NICE!','BOOP!','WOW!','BONK!','FAST!'];b.addEventListener('click',e=>{n++;s.textContent=n;level.textContent=1+Math.floor(n/25);if(n>r){r=n;best.textContent=r;localStorage.setItem('click-best',r)}b.classList.add('hit');setTimeout(()=>b.classList.remove('hit'),90);const p=document.createElement('span');p.className='pop';p.textContent=words[Math.floor(Math.random()*words.length)];p.style.left=(e.clientX-20)+'px';p.style.top=(e.clientY-20)+'px';p.style.color='hsl('+Math.floor(Math.random()*360)+' 85% 45%)';document.body.appendChild(p);setTimeout(()=>p.remove(),750)});
</script>
</body>
</html>
EOF
        ;;
    2)
        blue "Шаблон: Retro Terminal"
        cat > "$DECOY_ROOT/index.html" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="remna-decoy" content="ready"><title>Console</title><style>body{margin:0;min-height:100vh;background:#050806;color:#7cff9b;font:16px/1.65 ui-monospace,SFMono-Regular,Consolas,monospace;display:grid;place-items:center;text-shadow:0 0 8px #28ff6840}.term{width:min(860px,90vw);border:1px solid #246c38;background:#07100a;padding:28px;box-shadow:0 0 60px #00ff4420,inset 0 0 40px #00ff4408}.bar{color:#b7ffc7;border-bottom:1px solid #194d28;padding-bottom:12px;margin-bottom:18px}.dim{color:#48945b}.cursor{display:inline-block;width:9px;height:18px;background:#7cff9b;vertical-align:-4px;animation:b 1s steps(1) infinite}@keyframes b{50%{opacity:0}}</style></head><body><main class="term"><div class="bar">SYSTEM CONSOLE // ${DOMAIN}</div><div>&gt; boot edge-service</div><div class="dim">[ok] network initialized</div><div class="dim">[ok] tls endpoint ready</div><div class="dim">[ok] health checks passed</div><br><div>&gt; status</div><div>ONLINE</div><br><div>&gt; <span class="cursor"></span></div></main></body></html>
EOF
        ;;
    3)
        blue "Шаблон: IT-компания / веб-студия"
        cat > "$DECOY_ROOT/index.html" <<EOF
<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="remna-decoy" content="ready">
<title>Nordix Digital — разработка и поддержка веб-сервисов</title>
<style>*{box-sizing:border-box}body{margin:0;font-family:-apple-system,Segoe UI,Roboto,Inter,sans-serif;color:#131c2e;background:#fff}
header{position:sticky;top:0;background:#fff;border-bottom:1px solid #eceef3;z-index:5}
.nav{max-width:1100px;margin:0 auto;display:flex;align-items:center;justify-content:space-between;padding:18px 24px}
.logo{font-weight:800;font-size:19px;letter-spacing:-.02em}.logo span{color:#3b5bfd}
.nav a{color:#4a5473;text-decoration:none;font-size:14px;margin-left:26px}
.cta{background:#3b5bfd;color:#fff!important;padding:9px 16px;border-radius:9px;font-weight:600}
.hero{max-width:1100px;margin:0 auto;padding:80px 24px 60px;display:grid;grid-template-columns:1.1fr .9fr;gap:40px;align-items:center}
h1{font-size:clamp(30px,4.2vw,46px);line-height:1.15;margin:0 0 16px}
.hero p{color:#59617a;font-size:17px;line-height:1.6;max-width:480px}
.badges{display:flex;gap:10px;margin-top:26px;flex-wrap:wrap}
.badge{background:#f1f4ff;color:#3b5bfd;padding:7px 12px;border-radius:8px;font-size:13px;font-weight:600}
.panel{background:linear-gradient(160deg,#eef2ff,#fff);border:1px solid #e4e9fb;border-radius:20px;padding:26px;box-shadow:0 20px 60px rgba(30,50,120,.08)}
.panel .row{display:flex;justify-content:space-between;padding:10px 0;border-bottom:1px dashed #dde3f7;font-size:14px}
.panel .row:last-child{border:0}
.stats{background:#0e152b;color:#fff}
.stats-in{max-width:1100px;margin:0 auto;padding:52px 24px;display:grid;grid-template-columns:repeat(4,1fr);gap:24px;text-align:center}
.stats b{display:block;font-size:32px}
.stats span{color:#9aa4c7;font-size:13px}
.services{max-width:1100px;margin:0 auto;padding:70px 24px}
.services h2{font-size:28px;margin-bottom:34px}
.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:22px}
.card{border:1px solid #eceef3;border-radius:16px;padding:24px}
.card h3{margin:0 0 8px;font-size:17px}
.card p{color:#65708c;font-size:14px;line-height:1.55;margin:0}
footer{border-top:1px solid #eceef3;padding:28px 24px;text-align:center;color:#8c93ab;font-size:13px}
@media(max-width:820px){.hero{grid-template-columns:1fr}.grid{grid-template-columns:1fr}.stats-in{grid-template-columns:repeat(2,1fr)}.nav a{display:none}.nav a.cta{display:inline-block}}
</style></head><body>
<header><nav class="nav"><div class="logo">Nordix<span>.</span></div>
<div><a href="#">Услуги</a><a href="#">Кейсы</a><a href="#">Команда</a><a href="#" class="cta">Обсудить проект</a></div>
</nav></header>
<section class="hero">
<div><h1>Разрабатываем и поддерживаем веб-сервисы для растущего бизнеса</h1>
<p>Бэкенд, интеграции и инфраструктура — от MVP до нагрузки в десятки тысяч запросов в минуту. Работаем на аутсорсе с 2016 года.</p>
<div class="badges"><span class="badge">Backend</span><span class="badge">DevOps</span><span class="badge">Интеграции 1С</span><span class="badge">Поддержка 24/7</span></div>
</div>
<div class="panel">
<div class="row"><span>Аптайм за 12 мес.</span><b>99.97%</b></div>
<div class="row"><span>Активных проектов</span><b>34</b></div>
<div class="row"><span>Среднее SLA</span><b>15 мин</b></div>
<div class="row"><span>Домен</span><b>${DOMAIN}</b></div>
</div>
</section>
<section class="stats"><div class="stats-in">
<div><b>8 лет</b><span>на рынке</span></div>
<div><b>120+</b><span>завершённых проектов</span></div>
<div><b>27</b><span>инженеров в штате</span></div>
<div><b>99.97%</b><span>средний аптайм</span></div>
</div></section>
<section class="services"><h2>Что делаем</h2>
<div class="grid">
<div class="card"><h3>Веб-разработка</h3><p>Сайты, личные кабинеты, внутренние панели — на стеке, который подберём под задачу и бюджет.</p></div>
<div class="card"><h3>Инфраструктура</h3><p>Проектируем отказоустойчивые окружения, настраиваем мониторинг и резервное копирование.</p></div>
<div class="card"><h3>Поддержка</h3><p>Берём готовый проект на сопровождение: багфиксы, обновления, дежурство по инцидентам.</p></div>
</div></section>
<footer>© Nordix Digital · ${DOMAIN} · Все права защищены</footer>
</body></html>
EOF
        ;;
    4)
        blue "Шаблон: SaaS-продукт"
        cat > "$DECOY_ROOT/index.html" <<EOF
<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="remna-decoy" content="ready">
<title>Lumen — аналитика продаж в реальном времени</title>
<style>*{box-sizing:border-box}body{margin:0;font-family:-apple-system,Segoe UI,Roboto,Inter,sans-serif;color:#101423;background:#fbfbfe}
header{padding:18px 0;border-bottom:1px solid #ececf5}
.nav{max-width:1080px;margin:0 auto;display:flex;justify-content:space-between;align-items:center;padding:0 22px}
.logo{font-weight:800;font-size:18px}.logo i{color:#7c5cff;font-style:normal}
.nav a{color:#565b73;text-decoration:none;font-size:14px;margin-left:24px}
.cta{background:#7c5cff;color:#fff!important;padding:9px 16px;border-radius:10px;font-weight:600}
.hero{max-width:820px;margin:0 auto;text-align:center;padding:74px 22px 50px}
.pill{display:inline-block;background:#f1ecff;color:#7c5cff;padding:6px 14px;border-radius:999px;font-size:13px;font-weight:600;margin-bottom:18px}
h1{font-size:clamp(30px,5vw,48px);line-height:1.14;margin:0 0 16px}
.hero p{color:#5c627a;font-size:17px;max-width:560px;margin:0 auto 30px}
.btnrow{display:flex;gap:12px;justify-content:center}
.btn2{border:1px solid #dfe1ee;padding:11px 20px;border-radius:10px;color:#101423;text-decoration:none;font-weight:600;font-size:14px}
.btn1{background:#101423;color:#fff;padding:11px 20px;border-radius:10px;text-decoration:none;font-weight:600;font-size:14px}
.shot{max-width:980px;margin:10px auto 60px;padding:0 22px}
.shot .inner{background:#101423;border-radius:18px;padding:22px;box-shadow:0 30px 80px rgba(20,20,50,.18)}
.shot .bar{display:flex;gap:6px;margin-bottom:16px}.shot .dot{width:10px;height:10px;border-radius:50%;background:#3a3f57}
.mini{background:#171c30;border-radius:12px;padding:18px;display:grid;grid-template-columns:repeat(3,1fr);gap:14px}
.mini div{color:#8891b3;font-size:12px}.mini b{display:block;color:#fff;font-size:22px;margin-top:4px}
.pricing{max-width:1000px;margin:0 auto;padding:20px 22px 80px;display:grid;grid-template-columns:repeat(3,1fr);gap:20px}
.plan{border:1px solid #ececf5;border-radius:16px;padding:26px}
.plan.pop{border-color:#7c5cff;box-shadow:0 20px 50px rgba(124,92,255,.15)}
.plan h3{margin:0 0 4px;font-size:16px}.plan .price{font-size:30px;font-weight:800;margin:10px 0}
.plan ul{padding-left:18px;color:#5c627a;font-size:13.5px;line-height:1.9;margin:0}
footer{border-top:1px solid #ececf5;padding:26px 22px;text-align:center;color:#8c93ab;font-size:13px}
@media(max-width:760px){.pricing{grid-template-columns:1fr}.mini{grid-template-columns:1fr 1fr}.nav a:not(.cta){display:none}}
</style></head><body>
<header><nav class="nav"><div class="logo">Lumen<i>.</i></div>
<div><a href="#">Продукт</a><a href="#">Тарифы</a><a href="#">Документация</a><a href="#" class="cta">Войти</a></div>
</nav></header>
<section class="hero">
<span class="pill">Уже на ${DOMAIN}</span>
<h1>Вся аналитика продаж — в одной панели</h1>
<p>Lumen собирает данные из вашей CRM, склада и рекламных кабинетов и показывает, что реально влияет на выручку.</p>
<div class="btnrow"><a class="btn1" href="#">Начать бесплатно</a><a class="btn2" href="#">Смотреть демо</a></div>
</section>
<section class="shot"><div class="inner">
<div class="bar"><span class="dot"></span><span class="dot"></span><span class="dot"></span></div>
<div class="mini">
<div>Выручка за 30 дней<b>4.82М ₽</b></div>
<div>Средний чек<b>3 140 ₽</b></div>
<div>Конверсия<b>3.8%</b></div>
</div>
</div></section>
<section class="pricing">
<div class="plan"><h3>Start</h3><div class="price">0 ₽</div><ul><li>1 источник данных</li><li>7 дней истории</li><li>Email-поддержка</li></ul></div>
<div class="plan pop"><h3>Growth</h3><div class="price">2 990 ₽/мес</div><ul><li>Неограниченно источников</li><li>Полная история</li><li>Приоритетная поддержка</li></ul></div>
<div class="plan"><h3>Scale</h3><div class="price">по запросу</div><ul><li>Выделенный менеджер</li><li>SLA и SSO</li><li>Кастомные отчёты</li></ul></div>
</section>
<footer>© Lumen Analytics · ${DOMAIN}</footer>
</body></html>
EOF
        ;;
    5)
        blue "Шаблон: Корпоративный блог"
        cat > "$DECOY_ROOT/index.html" <<EOF
<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="remna-decoy" content="ready">
<title>Журнал ${DOMAIN} — заметки о продукте и инженерии</title>
<style>*{box-sizing:border-box}body{margin:0;font-family:Georgia,'Times New Roman',serif;color:#1c1c1c;background:#fdfdfb}
header{border-bottom:2px solid #1c1c1c;padding:22px 0}
.nav{max-width:860px;margin:0 auto;display:flex;justify-content:space-between;align-items:baseline;padding:0 20px;font-family:-apple-system,Segoe UI,sans-serif}
.logo{font-family:Georgia,serif;font-weight:700;font-size:22px}
.nav a{color:#555;text-decoration:none;font-size:13px;margin-left:20px;text-transform:uppercase;letter-spacing:.04em}
.wrap{max-width:860px;margin:0 auto;padding:34px 20px 70px}
.lede{font-family:-apple-system,Segoe UI,sans-serif;color:#777;font-size:13px;text-transform:uppercase;letter-spacing:.06em;margin-bottom:26px}
article{border-bottom:1px solid #e6e3db;padding:26px 0}
article:first-of-type{padding-top:0}
.tag{font-family:-apple-system,Segoe UI,sans-serif;color:#a3742a;font-size:12px;font-weight:700;text-transform:uppercase;letter-spacing:.05em}
h2{font-size:25px;margin:8px 0 8px;line-height:1.25}
h2 a{color:#1c1c1c;text-decoration:none}
p{color:#41403c;line-height:1.65;font-size:16px;margin:0 0 10px}
.meta{font-family:-apple-system,Segoe UI,sans-serif;color:#8a8a86;font-size:12.5px}
footer{font-family:-apple-system,Segoe UI,sans-serif;text-align:center;color:#8c93ab;font-size:13px;padding:26px 20px;border-top:1px solid #e6e3db}
</style></head><body>
<header><div class="nav"><div class="logo">Журнал</div><div><a href="#">Продукт</a><a href="#">Инженерия</a><a href="#">Команда</a></div></div></header>
<div class="wrap">
<div class="lede">${DOMAIN} · заметки команды</div>
<article><span class="tag">Инфраструктура</span><h2><a href="#">Как мы сократили время отклика API в три раза</a></h2>
<p>Разбираем, какие изменения в кэшировании и маршрутизации запросов дали наибольший эффект — и почему часть идей пришлось откатить.</p>
<div class="meta">12 минут чтения</div></article>
<article><span class="tag">Продукт</span><h2><a href="#">Редизайн онбординга: что показали метрики через месяц</a></h2>
<p>Сравниваем воронку до и после изменений, объясняем, какие гипотезы не подтвердились.</p>
<div class="meta">7 минут чтения</div></article>
<article><span class="tag">Команда</span><h2><a href="#">Как устроены дежурства в распределённой команде</a></h2>
<p>Формат ротации, эскалации и то, как мы считаем нагрузку на инженера на смене.</p>
<div class="meta">5 минут чтения</div></article>
</div>
<footer>© Журнал ${DOMAIN}</footer>
</body></html>
EOF
        ;;
    6)
        blue "Шаблон: Status Page"
        cat > "$DECOY_ROOT/index.html" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="remna-decoy" content="ready"><title>Service Status</title><style>*{box-sizing:border-box}body{margin:0;background:#f5f7fb;color:#172033;font-family:Inter,system-ui,-apple-system,Segoe UI,sans-serif}.wrap{width:min(900px,92vw);margin:9vh auto}.top{display:flex;justify-content:space-between;align-items:center;margin-bottom:28px}h1{margin:0;font-size:32px}.ok{background:#dcfce7;color:#166534;padding:9px 14px;border-radius:999px;font-weight:700}.hero,.row{background:#fff;border:1px solid #e7ebf2;border-radius:18px;box-shadow:0 10px 30px rgba(39,54,84,.06)}.hero{padding:28px;margin-bottom:18px}.hero b{font-size:24px}.hero p{color:#718096}.row{display:grid;grid-template-columns:1fr auto;gap:20px;padding:18px 22px;margin:10px 0}.dot{width:10px;height:10px;border-radius:50%;background:#22c55e;display:inline-block;margin-right:9px}small{color:#94a3b8}</style></head><body><main class="wrap"><div class="top"><h1>Service status</h1><span class="ok">All systems operational</span></div><section class="hero"><b>${DOMAIN}</b><p>Live service health and availability.</p><small>Last checked just now</small></section><div class="row"><span><i class="dot"></i>Web gateway</span><b>Operational</b></div><div class="row"><span><i class="dot"></i>Network edge</span><b>Operational</b></div><div class="row"><span><i class="dot"></i>API</span><b>Operational</b></div><div class="row"><span><i class="dot"></i>DNS</span><b>Operational</b></div></main></body></html>
EOF
        ;;
    7)
        blue "Шаблон: Minimal"
        cat > "$DECOY_ROOT/index.html" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="remna-decoy" content="ready"><title>Welcome</title><style>body{margin:0;background:#0f172a;color:#e2e8f0;font-family:system-ui,-apple-system,Segoe UI,sans-serif;display:grid;place-items:center;min-height:100vh}main{max-width:680px;padding:48px;text-align:center}h1{font-size:2.2rem;margin:0 0 12px}p{color:#94a3b8;line-height:1.6}</style></head><body><main><h1>Welcome</h1><p>${DOMAIN} is online.</p></main></body></html>
EOF
        ;;
esac
}

# ------------------------------------------------------------
# Шаги
# ------------------------------------------------------------

preflight() {
    [[ "$(id -u)" == "0" ]] || die "Запусти скрипт от root."
    command -v apt-get >/dev/null 2>&1 || die "Нужен Debian/Ubuntu (apt-get не найден)."

    if [[ "$IS_TTY" != "1" ]]; then
        [[ -n "$ROLE" ]] || die "Скрипт интерактивный. Для автоматического запуска задай ROLE=ru|eu переменной окружения."
        [[ -n "$NODE_SECRET" ]] || die "Скрипт интерактивный. Задай NODE_SECRET переменной окружения."
        if [[ "$ROLE" == "ru" ]]; then
            [[ -n "$EU_LINK" ]] || die "Для ROLE=ru в неинтерактивном режиме нужен EU_LINK."
        else
            [[ -n "$DOMAIN" && -n "$EMAIL" ]] || die "Для ROLE=eu в неинтерактивном режиме нужны DOMAIN и EMAIL."
        fi
    fi

    # python3 и curl нужны до основной установки (разбор ссылки, определение IP)
    local missing=()
    command -v python3 >/dev/null 2>&1 || missing+=(python3)
    command -v curl >/dev/null 2>&1 || missing+=(curl ca-certificates)
    if (( ${#missing[@]} > 0 )); then
        blue "Ставим недостающее: ${missing[*]}"
        apt-get update
        apt-get install -y "${missing[@]}"
    fi

    local busy
    busy="$(ss -H -lntp "sport = :${VLESS_PORT}" 2>/dev/null || true)"
    if [[ -n "$busy" ]]; then
        if grep -Eq 'rw-core|xray' <<<"$busy"; then
            blue "TCP/${VLESS_PORT} уже занят Xray (повторный запуск) — это нормально."
        else
            yellow "TCP/${VLESS_PORT} уже занят другим сервисом:"
            echo "$busy"
            yellow "Xray не сможет занять этот порт. Освободи его (nginx/apache/x-ui и т.п.)."
            confirm "Продолжить всё равно?" n || die "Остановлено пользователем."
        fi
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        yellow "ufw включён. Не забудь открыть порты:"
        yellow "  ufw allow ${VLESS_PORT}/tcp   и   ufw allow from <IP_панели> to any port ${NODE_PORT:-2222} proto tcp"
    fi
}

banner() {
    echo
    echo "============================================================"
    echo " Remnawave cascade installer (RU-вход / EU-выход)"
    echo "============================================================"
    echo
    echo "Полная схема каскада:"
    echo "  HAPP -> TCP/443 -> [RU-нода] -> RU напрямую"
    echo "                              \\-> [EU-нода] -> WARP -> Internet"
    echo
}

ask_questions() {
    if [[ -z "$ROLE" ]]; then
        echo
        echo "Что ставим на этот сервер?"
        echo "  1) RU-вход каскада   — принимает клиентов, шлёт трафик на EU-ноду"
        echo "  2) EU-выход          — self-steal + Cloudflare WARP (либо просто DIRECT)"
        local role_choice
        ask_choice role_choice "Роль" "1" '^[1-2]$'
        [[ "$role_choice" == "1" ]] && ROLE="ru" || ROLE="eu"
    fi
    [[ "$ROLE" == "ru" || "$ROLE" == "eu" ]] \
        || die "ROLE должен быть 'ru' или 'eu' (задано: $ROLE)."

    [[ "$ROLE" == "eu" ]] && ENTRY_TAG="VLESS_SELF_STEAL_WARP"

    if [[ "$ROLE" == "ru" ]]; then
        blue "Ставим RU-вход: клиенты -> эта нода -> EU-нода -> интернет."
    else
        blue "Ставим EU-выход: сервисный пользователь с RU-ноды -> эта нода -> интернет (WARP или DIRECT)."
    fi

    ask NODE_SECRET "SECRET_KEY этой ноды из Remnawave (Nodes -> Create)"
    ask NODE_PORT "Node API port" "2222"
    [[ "$NODE_PORT" =~ ^[0-9]+$ ]] || die "Node API port должен быть числом."
    (( NODE_PORT >= 1 && NODE_PORT <= 65535 )) || die "Некорректный Node API port."

    echo
    echo "Имя контейнера/процесса ноды. По умолчанию образ называется 'remnanode' —"
    echo "это само по себе выдаёт VPN в 'docker ps'/'docker images'. Можно задать"
    echo "нейтральное имя (например cache-worker, media-sync, log-agent)."
    ask CONTAINER_NAME "Имя контейнера" "cache-worker"
    [[ "$CONTAINER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] \
        || die "Имя контейнера может содержать только буквы, цифры, . _ -"

    if [[ "$ROLE" == "ru" ]]; then
        ask_questions_ru
    else
        ask_questions_eu
    fi
}

ask_questions_ru() {
    echo
    echo "Шаблон маскировки входа (что увидит DPI и оператор):"
    echo "  1) SNI ya.ru        — для белых списков, домен не нужен"
    echo "  2) SNI vk.com       — для белых списков, домен не нужен"
    echo "  3) SNI ozon.ru      — для белых списков, домен не нужен"
    echo "  4) Свой SNI         — любой домен из белого списка оператора"
    echo "  5) Self-steal       — свой домен + сайт-заглушка + Let's Encrypt"
    echo "     (сработает, только если оператор проверяет IP, а не SNI)"
    ask_choice ENTRY_MODE "Шаблон" "1" '^[1-5]$'

    case "$ENTRY_MODE" in
        1) REALITY_SNI="ya.ru" ;;
        2) REALITY_SNI="vk.com" ;;
        3) REALITY_SNI="ozon.ru" ;;
        4)
            ask REALITY_SNI "SNI (домен из белого списка, например ads.x5.ru)"
            [[ "$REALITY_SNI" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
                || die "Некорректный домен SNI."
            ;;
        5)
            USE_SELFSTEAL=1
            ask_domain_email_decoy
            REALITY_SNI="$DOMAIN"
            ;;
    esac

    if [[ "$USE_SELFSTEAL" == "1" ]]; then
        REALITY_TARGET="127.0.0.1:${SELF_PORT}"
    else
        REALITY_TARGET="${REALITY_SNI}:443"
    fi

    echo
    echo "Выходная (EU) нода."
    echo "В панели: создай сервисного пользователя на EU-ноде и скопируй его"
    echo "vless://-ссылку (Reality, tcp/raw или xhttp)."
    ask EU_LINK "Ссылка vless:// EU-ноды"
    tool parse "$EU_LINK" > "$LINK_JSON" || die "Не удалось разобрать ссылку EU-ноды."
    chmod 600 "$LINK_JSON"

    echo "  EU: $(tool get "$LINK_JSON" address):$(tool get "$LINK_JSON" port)" \
         "| SNI $(tool get "$LINK_JSON" sni)" \
         "| транспорт $(tool get "$LINK_JSON" type)" \
         "| flow '$(tool get "$LINK_JSON" flow)'"

    echo
    echo "Шаблон маршрутов:"
    echo "  1) RU-сайты и RU-IP напрямую с этой ноды, остальное в EU (рекомендуется)"
    echo "  2) Весь трафик в EU"
    ask_choice ROUTE_TEMPLATE "Маршруты" "1" '^[1-2]$'
    if [[ "$ROUTE_TEMPLATE" == "1" ]]; then
        ask_opt EXTRA_DIRECT "Доп. домены напрямую через RU (через запятую, Enter — пропустить)"
    fi
}

ask_questions_eu() {
    USE_SELFSTEAL=1
    ask_domain_email_decoy
    REALITY_SNI="$DOMAIN"
    REALITY_TARGET="127.0.0.1:${SELF_PORT}"

    echo
    echo "Выход в интернет с этой ноды:"
    echo "  y) через Cloudflare WARP (обычно нужно для EU-выхода каскада)"
    echo "  n) напрямую (DIRECT) — без WARP"
    if [[ -z "$WARP_ENABLED" ]]; then
        confirm "Использовать WARP?" y && WARP_ENABLED=1 || WARP_ENABLED=0
    fi
    [[ "$WARP_ENABLED" == "1" || "$WARP_ENABLED" == "0" ]] \
        || die "WARP_ENABLED должен быть 1 или 0 (задано: $WARP_ENABLED)."
}

ask_domain_email_decoy() {
    ask DOMAIN "Домен self-steal (например vpn.example.com)"
    ask EMAIL "Email для Let's Encrypt"
    echo
    echo "Шаблон сайта-заглушки:"
    echo "  Игрушечные (проще узнать, что сайт ненастоящий):"
    echo "  1) Весёлый кликер"
    echo "  2) Retro Terminal"
    echo "  Похожие на настоящий бизнес-сайт (рекомендую для self-steal):"
    echo "  3) IT-компания / веб-студия — лендинг с услугами и портфолио"
    echo "  4) SaaS-продукт — лендинг с тарифами и фичами"
    echo "  5) Корпоративный блог / новости — статьи с датами"
    echo "  6) Status Page — страница мониторинга сервиса"
    echo "  7) Minimal — пустая страница-заглушка"
    ask_choice DECOY_TEMPLATE "Заглушка" "3" '^[1-7]$'
}

check_dns_if_needed() {
    detect_server_ip
    [[ "$USE_SELFSTEAL" == "1" ]] || return 0

    blue "Проверяем DNS домена..."
    local domain_ip
    domain_ip="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
    [[ -n "$domain_ip" ]] || die "Домен $DOMAIN не имеет доступной IPv4 A-записи."

    echo "  Domain IPv4: $domain_ip"
    [[ -n "$SERVER_IP" ]] && echo "  Server IPv4: $SERVER_IP"

    if [[ -n "$SERVER_IP" && "$domain_ip" != "$SERVER_IP" ]]; then
        yellow "A-запись домена ($domain_ip) не совпадает с внешним IPv4 сервера ($SERVER_IP)."
        yellow "Let's Encrypt или подключение клиента могут не заработать."
        confirm "Продолжить?" n || die "Остановлено пользователем."
    fi
}

install_deps() {

    blue "Устанавливаем системные зависимости..."
    local pkgs=(curl ca-certificates openssl python3 iproute2)
    if [[ "$USE_SELFSTEAL" == "1" ]]; then
        pkgs+=(nginx certbot)
    fi
    if [[ "$ROLE" == "eu" && "$WARP_ENABLED" == "1" ]]; then
        pkgs+=(zstd tar)
    fi
    apt-get update
    apt-get install -y "${pkgs[@]}"
    green "Системные зависимости установлены."
}

install_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        blue "Устанавливаем Docker..."
        if ! curl -fsSL --max-time 60 https://get.docker.com | sh; then
            yellow "get.docker.com недоступен — ставим Docker из репозитория дистрибутива."
            apt-get install -y docker.io
            apt-get install -y docker-compose-v2 \
                || apt-get install -y docker-compose-plugin \
                || true
        fi
    fi
    systemctl enable --now docker >/dev/null 2>&1 || true
    docker --version >/dev/null || die "Docker не работает."
    docker compose version >/dev/null 2>&1 || die "Docker Compose plugin недоступен."
    green "Docker готов."
}

write_node_env() {
    cat > "$NODE_DIR/.env" <<EOF
NODE_PORT=$NODE_PORT
SECRET_KEY=$NODE_SECRET
NODE_IMAGE=$NODE_IMAGE
EOF
    chmod 600 "$NODE_DIR/.env"
}

install_node() {
    blue "Настраиваем Remnawave Node..."
    mkdir -p "$NODE_DIR"
    write_node_env

    cat > "$NODE_DIR/docker-compose.yml" <<EOF
services:
  ${CONTAINER_NAME}:
    image: \${NODE_IMAGE}
    container_name: ${CONTAINER_NAME}
    hostname: ${CONTAINER_NAME}
    network_mode: host
    restart: always

    cap_add:
      - NET_ADMIN

    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

    environment:
      - NODE_PORT=\${NODE_PORT}
      - SECRET_KEY=\${SECRET_KEY}
EOF

    cd "$NODE_DIR"

    if ! docker compose pull; then
        yellow "Не удалось скачать ${NODE_IMAGE} (Docker Hub бывает недоступен из РФ)."
        yellow "Пробуем зеркало GHCR: ${NODE_IMAGE_GHCR}"
        NODE_IMAGE="$NODE_IMAGE_GHCR"
        write_node_env
        docker compose pull || die "Не удалось скачать образ ноды. Настрой registry-mirrors в /etc/docker/daemon.json или загрузи образ вручную."
    fi

    # Локальный тег без слов remnawave/node — "docker images" тоже не должен
    # выдавать VPN с первого взгляда. Полностью удалять оригинальный тег не
    # стал: если сборка образа под новым тегом не удастся, откатимся на него.
    local local_tag="local/${CONTAINER_NAME}:latest"
    if docker tag "$NODE_IMAGE" "$local_tag" 2>/dev/null; then
        NODE_IMAGE="$local_tag"
        write_node_env
    else
        yellow "Не удалось переименовать образ локально, останется тег ${NODE_IMAGE}."
    fi

    docker compose up -d

    blue "Ждём запуска Remnawave Node..."
    local ready=0 _
    for _ in $(seq 1 30); do
        if port_listening "$NODE_PORT"; then
            ready=1
            break
        fi
        sleep 1
    done

    if [[ "$ready" != "1" ]]; then
        docker logs "$CONTAINER_NAME" --tail=150 2>&1 || true
        die "Remnawave Node не слушает API port ${NODE_PORT}."
    fi

    green "Remnawave Node запущена на API port ${NODE_PORT}."
    blue "Xray: $(docker exec "$CONTAINER_NAME" /usr/local/bin/xray version 2>/dev/null | head -1 || echo unknown)"
}

gen_reality() {
    local keyfile="$WORK/reality.env"

    if [[ -s "$keyfile" ]]; then
        if confirm "Найдены Reality-ключи от прошлого запуска. Использовать их?" y; then
            # shellcheck disable=SC1090
            source "$keyfile"
            if [[ -n "$REALITY_PRIVATE" && -n "$REALITY_PUBLIC" && -n "$SHORT_ID_1" && -n "$SHORT_ID_2" ]]; then
                green "Ключи Reality загружены."
                return 0
            fi
        fi
    fi

    blue "Генерируем Reality X25519 keypair..."

    local out
    out="$(docker exec "$CONTAINER_NAME" /usr/local/bin/xray x25519)"

    REALITY_PRIVATE="$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$out" | tr -d '[:space:]')"
    REALITY_PUBLIC="$(awk -F': *' 'tolower($1) ~ /public|password/ {print $2; exit}' <<<"$out" | tr -d '[:space:]')"

    [[ -n "$REALITY_PRIVATE" ]] || die "Не удалось получить Reality PrivateKey."
    [[ -n "$REALITY_PUBLIC" ]] || die "Не удалось получить Reality PublicKey."

    SHORT_ID_1="$(openssl rand -hex 8)"
    SHORT_ID_2="$(openssl rand -hex 8)"

    cat > "$keyfile" <<EOF
REALITY_PRIVATE=$REALITY_PRIVATE
REALITY_PUBLIC=$REALITY_PUBLIC
SHORT_ID_1=$SHORT_ID_1
SHORT_ID_2=$SHORT_ID_2
EOF
    chmod 600 "$keyfile"

    green "Reality keypair и ShortID созданы."
}

check_sni_target() {
    [[ "$USE_SELFSTEAL" == "0" ]] || return 0

    blue "Проверяем, что ${REALITY_SNI} отвечает по TLS с этого сервера..."
    local out
    out="$(timeout 30 docker exec "$CONTAINER_NAME" /usr/local/bin/xray tls ping "$REALITY_SNI" 2>&1 || true)"
    if [[ -z "$out" ]] || grep -qiE 'fail|error|timeout|refused|no such' <<<"$out"; then
        yellow "Не удалось подтвердить TLS-ответ от ${REALITY_SNI}:"
        echo "$out" | head -8
        yellow "Reality может не заработать. Выбери другой SNI, если клиент не подключится."
    else
        echo "$out" | head -8
        green "${REALITY_SNI} отвечает."
    fi
}

setup_selfsteal() {
    blue "Готовим decoy-сайт..."

    mkdir -p "$DECOY_ROOT/.well-known/acme-challenge"
    write_decoy_template
    printf '%s\n' 'remna-decoy-ready' > "$DECOY_ROOT/.decoy-ready"

    local site="/etc/nginx/sites-available/selfsteal-${DOMAIN}.conf"
    local link="/etc/nginx/sites-enabled/selfsteal-${DOMAIN}.conf"

    # Фаза 1: только HTTP (для ACME). Внешний 443 nginx не занимает никогда.
    cat > "$site" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${DECOY_ROOT};
    index index.html;

    location /.well-known/acme-challenge/ {
        root ${DECOY_ROOT};
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    ln -sfn "$site" "$link"
    if [[ -L /etc/nginx/sites-enabled/default ]]; then
        rm -f /etc/nginx/sites-enabled/default
    fi

    nginx -t || die "nginx config test failed."
    systemctl restart nginx
    green "nginx HTTP/ACME frontend готов."

    blue "Проверяем сертификат Let's Encrypt..."
    if [[ ! -s "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ||
          ! -s "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]]; then
        certbot certonly \
            --webroot \
            -w "$DECOY_ROOT" \
            -d "$DOMAIN" \
            --non-interactive \
            --agree-tos \
            -m "$EMAIL" \
            || die "Не удалось получить сертификат Let's Encrypt для $DOMAIN."
    fi

    [[ -s "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]] || die "fullchain.pem отсутствует."
    [[ -s "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]] || die "privkey.pem отсутствует."
    green "Сертификат Let's Encrypt готов."

    blue "Настраиваем nginx только на 80 и 127.0.0.1:${SELF_PORT}..."

    cat > "$site" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${DECOY_ROOT};
    index index.html;

    location /.well-known/acme-challenge/ {
        root ${DECOY_ROOT};
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}

server {
    listen 127.0.0.1:${SELF_PORT} ssl;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root ${DECOY_ROOT};
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

    nginx -t || die "Финальный nginx config test failed."
    systemctl restart nginx

    port_listening "$SELF_PORT" || die "nginx не слушает 127.0.0.1:${SELF_PORT}."

    local s443
    s443="$(ss -H -lntp "sport = :443" 2>/dev/null || true)"
    if grep -q nginx <<<"$s443"; then
        red "nginx занимает внешний TCP/443:"
        echo "$s443"
        die "Освободи внешний 443 от других nginx-конфигов и повтори запуск."
    fi

    curl -sk \
        --resolve "${DOMAIN}:${SELF_PORT}:127.0.0.1" \
        "https://${DOMAIN}:${SELF_PORT}/.decoy-ready" \
        --connect-timeout 5 --max-time 10 \
        | grep -qx "remna-decoy-ready" \
        || die "Локальный HTTPS self-steal тест на ${SELF_PORT} не прошёл."

    green "Self-steal nginx работает на 127.0.0.1:${SELF_PORT}."
}

# Запускает временный Xray (HTTP-прокси -> EU outbound) и проверяет выход.
# Возвращает 0, если получили ответ Cloudflare trace.
run_eu_test() {
    tool testconf "$WORK/eu-outbound.json" --port "$TEST_PORT" > "$WORK/eu-test.json"
    chmod 600 "$WORK/eu-test.json"

    docker cp "$WORK/eu-test.json" "$CONTAINER_NAME":/tmp/eu-test.json >/dev/null
    cleanup_test

    docker exec "$CONTAINER_NAME" sh -c '
        /usr/local/bin/xray run -c /tmp/eu-test.json >/tmp/eu-test.log 2>&1 &
        echo $! >/tmp/eu-test.pid
    '

    local up=0 _
    for _ in $(seq 1 20); do
        if port_listening "$TEST_PORT"; then
            up=1
            break
        fi
        sleep 0.25
    done

    if [[ "$up" != "1" ]]; then
        docker exec "$CONTAINER_NAME" sh -c 'cat /tmp/eu-test.log 2>/dev/null' > "$WORK/eu-test.log" || true
        cleanup_test
        return 1
    fi

    local trace
    trace="$(curl -fsS -x "http://127.0.0.1:${TEST_PORT}" \
        https://www.cloudflare.com/cdn-cgi/trace \
        --connect-timeout 10 --max-time 25 2>/dev/null || true)"

    docker exec "$CONTAINER_NAME" sh -c 'cat /tmp/eu-test.log 2>/dev/null' > "$WORK/eu-test.log" || true
    cleanup_test

    if ! grep -q '^ip=' <<<"$trace"; then
        return 1
    fi

    EU_EXIT_IP="$(awk -F= '/^ip=/ {print $2; exit}' <<<"$trace")"
    EU_LOC="$(awk -F= '/^loc=/ {print $2; exit}' <<<"$trace")"
    EU_WARP="$(awk -F= '/^warp=/ {print $2; exit}' <<<"$trace")"
    return 0
}

test_eu_exit() {
    blue "Проверяем цепочку RU -> EU..."

    local host port
    host="$(tool get "$LINK_JSON" address)"
    port="$(tool get "$LINK_JSON" port)"

    if [[ "${SKIP_TCP_CHECK:-0}" != "1" ]]; then
        if ! timeout 8 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
            die "EU-нода ${host}:${port} недоступна с этого сервера (файрвол EU-ноды или неверный адрес)."
        fi
        green "TCP до ${host}:${port} доходит."
    fi

    local -a list
    mapfile -t list < <(tool variants "$LINK_JSON")

    local v fmt net ok=0
    for v in "${list[@]}"; do
        fmt="${v%%:*}"
        net="${v##*:}"
        tool outbound "$LINK_JSON" --fmt "$fmt" --net "$net" > "$WORK/eu-outbound.json"
        chmod 600 "$WORK/eu-outbound.json"
        blue "Формат outbound: ${v}"
        if run_eu_test; then
            ok=1
            USED_VARIANT="$v"
            break
        fi
        yellow "Формат ${v} не сработал."
    done

    if [[ "$ok" != "1" ]]; then
        red "Тест EU-выхода не прошёл."
        echo "--- лог тестового Xray ---"
        cat "$WORK/eu-test.log" 2>/dev/null || true
        echo "--------------------------"
        die "Проверь vless://-ссылку, пользователя на EU-ноде и то, что EU-нода принимает подключения с этого IP."
    fi

    rm -f "$WORK/eu-test.json" "$WORK/eu-test.log"

    green "Цепочка работает (outbound: ${USED_VARIANT})."
    green "EU exit IP: ${EU_EXIT_IP:-unknown} | страна: ${EU_LOC:-unknown} | warp=${EU_WARP:-off}"

    if [[ -n "$SERVER_IP" && "$EU_EXIT_IP" == "$SERVER_IP" ]]; then
        yellow "Выходной IP совпадает с IP этого сервера — трафик не ушёл в EU. Проверь ссылку."
    fi
}

# ------------------------------------------------------------
# WARP (только для роли EU)
# ------------------------------------------------------------

install_wgcf() {
    blue "Устанавливаем актуальный wgcf-cli..."

    local arch asset
    arch="$(uname -m)"
    case "$arch" in
        x86_64) asset="wgcf-cli-linux-64.tar.zstd" ;;
        aarch64|arm64) asset="wgcf-cli-linux-arm64-v8a.tar.zstd" ;;
        *) die "Неподдерживаемая архитектура: $arch" ;;
    esac

    local release_json wgcf_url
    release_json="$(curl -fsSL https://api.github.com/repos/ArchiveNetwork/wgcf-cli/releases/latest)" \
        || die "Не удалось получить информацию о релизе wgcf-cli."

    wgcf_url="$(tool ghasset --asset "$asset" <<<"$release_json")"
    [[ -n "$wgcf_url" && "$wgcf_url" != "None" ]] || die "Не найден asset ${asset}."

    rm -rf "$WORK/wgcf-cli"
    mkdir -p "$WORK/wgcf-cli"
    curl -fL "$wgcf_url" -o "$WORK/wgcf-cli.tar.zstd" || die "Не удалось скачать wgcf-cli."
    tar --zstd -xf "$WORK/wgcf-cli.tar.zstd" -C "$WORK/wgcf-cli" \
        || die "Не удалось распаковать wgcf-cli."

    local wgcf_bin
    wgcf_bin="$(find "$WORK/wgcf-cli" -type f -name wgcf-cli | head -1)"
    [[ -n "$wgcf_bin" ]] || die "wgcf-cli binary не найден."

    install -m 755 "$wgcf_bin" /usr/local/bin/wgcf-cli
    command -v wgcf-cli >/dev/null || die "wgcf-cli не установлен."
    green "wgcf-cli установлен."
}

register_warp_and_build_outbound() {
    blue "Регистрируем новый Cloudflare WARP profile..."

    rm -f "$WORK/wgcf.json" "$WORK"/*.xray.json "$WORK/warp-outbound.json"

    wgcf-cli register -c "$WORK/wgcf.json" > "$WORK/wgcf-register-output.txt" \
        || die "Не удалось зарегистрировать WARP profile."
    chmod 600 "$WORK/wgcf.json" "$WORK/wgcf-register-output.txt"

    wgcf-cli generate -c "$WORK/wgcf.json" --xray >/dev/null \
        || die "wgcf-cli generate --xray завершился с ошибкой."

    local xray_warp_file="$WORK/wgcf.xray.json"
    if [[ ! -f "$xray_warp_file" ]]; then
        xray_warp_file="$(find "$WORK" -maxdepth 1 -type f -name '*.xray.json' | head -1)"
    fi
    [[ -f "$xray_warp_file" ]] || die "wgcf-cli не создал Xray WARP config."
    chmod 600 "$xray_warp_file"

    tool checkwarp "$xray_warp_file" || die "Сгенерированный WARP-конфиг неполный (secretKey/publicKey/reserved)."

    blue "Формируем WARP outbound..."
    local warp_ip
    warp_ip="$(getent ahostsv4 engage.cloudflareclient.com | awk 'NR==1 {print $1}')"
    [[ -n "$warp_ip" ]] || die "Не удалось определить IPv4 engage.cloudflareclient.com."

    tool warpadapt "$xray_warp_file" --endpoint "${warp_ip}:2408" > "$WORK/warp-outbound.json" \
        || die "Не удалось адаптировать WARP outbound."
    chmod 600 "$WORK/warp-outbound.json"

    green "WARP outbound создан. Endpoint: ${warp_ip}:2408"
}

run_warp_test() {
    tool testconf "$WORK/warp-outbound.json" --port "$WARP_TEST_PORT" > "$WORK/warp-test.json"
    chmod 600 "$WORK/warp-test.json"

    docker cp "$WORK/warp-test.json" "$CONTAINER_NAME":/tmp/warp-test.json >/dev/null
    cleanup_test

    docker exec "$CONTAINER_NAME" sh -c '
        /usr/local/bin/xray run -c /tmp/warp-test.json >/tmp/warp-test.log 2>&1 &
        echo $! >/tmp/warp-test.pid
    '

    local up=0 _
    for _ in $(seq 1 20); do
        if port_listening "$WARP_TEST_PORT"; then
            up=1
            break
        fi
        sleep 0.25
    done

    if [[ "$up" != "1" ]]; then
        docker exec "$CONTAINER_NAME" sh -c 'cat /tmp/warp-test.log 2>/dev/null' > "$WORK/warp-test.log" || true
        cleanup_test
        return 1
    fi

    local trace
    trace="$(curl -fsS -x "http://127.0.0.1:${WARP_TEST_PORT}" \
        https://www.cloudflare.com/cdn-cgi/trace \
        --connect-timeout 10 --max-time 20 2>/dev/null || true)"

    docker exec "$CONTAINER_NAME" sh -c 'cat /tmp/warp-test.log 2>/dev/null' > "$WORK/warp-test.log" || true
    cleanup_test

    if ! grep -q '^warp=on$' <<<"$trace"; then
        echo "$trace"
        return 1
    fi

    WARP_EXIT_IP="$(awk -F= '/^ip=/ {print $2; exit}' <<<"$trace")"
    WARP_COLO="$(awk -F= '/^colo=/ {print $2; exit}' <<<"$trace")"
    WARP_LOC="$(awk -F= '/^loc=/ {print $2; exit}' <<<"$trace")"
    return 0
}

test_warp_exit() {
    blue "Запускаем независимый Xray -> WARP тест..."
    if ! run_warp_test; then
        red "WARP TEST FAILED"
        echo "--- лог тестового Xray ---"
        cat "$WORK/warp-test.log" 2>/dev/null || true
        echo "--------------------------"
        die "WARP не поднялся. Попробуй перерегистрировать профиль (повторный запуск скрипта) или проверь исходящий UDP на этом сервере."
    fi
    rm -f "$WORK/warp-test.json" "$WORK/warp-test.log"
    green "WARP TEST PASSED: warp=on"
    green "WARP Exit IP: ${WARP_EXIT_IP:-unknown} | Cloudflare POP: ${WARP_COLO:-unknown} | Location: ${WARP_LOC:-unknown}"
}

build_final_config() {
    if [[ "$ROLE" == "ru" ]]; then
        build_final_config_ru
    else
        build_final_config_eu
    fi
}

build_final_config_ru() {
    blue "Создаём финальный Remnawave Config Profile..."

    local split="1"
    [[ "$ROUTE_TEMPLATE" == "2" ]] && split="0"

    # Формат --опция=значение обязателен: ключи Reality (base64url) могут начинаться с "-"
    local common=(
        "--outbound=$WORK/eu-outbound.json"
        "--tag=$ENTRY_TAG"
        "--port=$VLESS_PORT"
        "--target=$REALITY_TARGET"
        "--sni=$REALITY_SNI"
        "--private=$REALITY_PRIVATE"
        "--sid1=$SHORT_ID_1"
        "--sid2=$SHORT_ID_2"
        "--split=$split"
        "--extra=$EXTRA_DIRECT"
    )

    tool final "${common[@]}" > "$WORK/final-config.json"
    chmod 600 "$WORK/final-config.json"

    tool check "$WORK/final-config.json" \
        "--tag=$ENTRY_TAG" "--port=$VLESS_PORT" \
        "--target=$REALITY_TARGET" "--sni=$REALITY_SNI" \
        || die "Финальный конфиг не прошёл внутреннюю проверку."

    validate_final_with_xray "${common[@]}"
    green "final-config.json создан."
}

build_final_config_eu() {
    blue "Создаём финальный Remnawave Config Profile..."

    local outbound_file="$WORK/warp-outbound.json"
    if [[ "$WARP_ENABLED" != "1" ]]; then
        outbound_file="$WORK/direct-outbound.json"
        printf '{"tag":"DIRECT","protocol":"freedom"}\n' > "$outbound_file"
    fi

    local common=(
        "--outbound=$outbound_file"
        "--tag=$ENTRY_TAG"
        "--port=$VLESS_PORT"
        "--target=$REALITY_TARGET"
        "--sni=$REALITY_SNI"
        "--private=$REALITY_PRIVATE"
        "--sid1=$SHORT_ID_1"
        "--sid2=$SHORT_ID_2"
        "--fingerprint=firefox"
        "--dns=8.8.8.8,8.8.4.4"
    )

    tool final_eu "${common[@]}" > "$WORK/final-config.json"
    chmod 600 "$WORK/final-config.json"

    tool check "$WORK/final-config.json" \
        "--tag=$ENTRY_TAG" "--port=$VLESS_PORT" \
        "--target=$REALITY_TARGET" "--sni=$REALITY_SNI" \
        "--outbound=$outbound_file" \
        || die "Финальный конфиг не прошёл внутреннюю проверку."

    validate_final_with_xray_eu "${common[@]}"
    green "final-config.json создан."
}

validate_final_with_xray() {
    # Проверка синтаксиса самим Xray (с тестовым клиентом, т.к. в профиле clients пуст)
    tool final "$@" --test-client > "$WORK/final-test.json"
    _validate_final_with_xray_common
}

validate_final_with_xray_eu() {
    tool final_eu "$@" --test-client > "$WORK/final-test.json"
    _validate_final_with_xray_common
}

_validate_final_with_xray_common() {
    chmod 600 "$WORK/final-test.json"
    docker cp "$WORK/final-test.json" "$CONTAINER_NAME":/tmp/final-test.json >/dev/null

    local out
    out="$(docker exec "$CONTAINER_NAME" /usr/local/bin/xray run -test -c /tmp/final-test.json 2>&1 || true)"
    docker exec "$CONTAINER_NAME" rm -f /tmp/final-test.json >/dev/null 2>&1 || true
    rm -f "$WORK/final-test.json"

    if grep -qi 'configuration ok' <<<"$out"; then
        green "Xray подтвердил конфиг (Configuration OK)."
    else
        yellow "Xray не подтвердил конфиг командой -test. Вывод:"
        echo "$out" | head -15
        yellow "Если панель примет профиль и нода поднимется — всё в порядке."
    fi
}

write_outputs() {
    if [[ "$ROLE" == "ru" ]]; then
        write_outputs_ru
    else
        write_outputs_eu
    fi
    write_check_sh
}

write_outputs_ru() {
    local addr_main="${SERVER_IP:-<IP_этого_сервера>}"
    local domain_line="" route_text="всё в EU"
    [[ "$USE_SELFSTEAL" == "1" ]] && domain_line=$'\n'"или домен: ${DOMAIN}"
    [[ "$ROUTE_TEMPLATE" == "1" ]] && route_text="RU напрямую, остальное в EU"

    cat > "$WORK/CLIENT.txt" <<EOF
============================================================
Remnawave -> Hosts -> Create (для inbound ${ENTRY_TAG})
============================================================

Address (рекомендую IP: белые списки часто работают по IP):
${addr_main}${domain_line}

Port:
${VLESS_PORT}

SNI / Server Name:
${REALITY_SNI}

Fingerprint:
firefox (на части клиентов chrome начали детектить; если не пойдёт — попробуй chrome)

Security / Network:
Reality / raw (tcp), flow xtls-rprx-vision

Для ручной проверки в клиенте (HAPP и т.п.):
  Reality PublicKey / PBK : ${REALITY_PUBLIC}
  Short ID #1             : ${SHORT_ID_1}
  Short ID #2             : ${SHORT_ID_2}

Reality target на сервере:
${REALITY_TARGET}

Цепочка:
  EU: $(tool get "$LINK_JSON" address):$(tool get "$LINK_JSON" port)  (outbound: ${USED_VARIANT})
  EU exit IP при установке: ${EU_EXIT_IP:-unknown} (${EU_LOC:-unknown}), warp=${EU_WARP:-off}

Маршруты: ${route_text}
============================================================
EOF
    chmod 600 "$WORK/CLIENT.txt"
}

write_outputs_eu() {
    local addr_main="${SERVER_IP:-<IP_этого_сервера>}"
    local warp_line="WARP: OFF (DIRECT)"
    if [[ "$WARP_ENABLED" == "1" ]]; then
        warp_line="WARP: ON
WARP Exit IP при установке: ${WARP_EXIT_IP:-unknown}
Cloudflare POP: ${WARP_COLO:-unknown}
Cloudflare location: ${WARP_LOC:-unknown}"
    fi

    cat > "$WORK/CLIENT.txt" <<EOF
============================================================
Remnawave -> Hosts -> Create (для inbound ${ENTRY_TAG})
Эта нода — EU-выход. Обычно сюда подключается только RU-вход
каскада (сервисный пользователь), а не конечные клиенты.
============================================================

Address:
${DOMAIN} (или ${addr_main})

Port:
${VLESS_PORT}

SNI / Server Name:
${DOMAIN}

Fingerprint:
firefox

Security / Network:
Reality / raw (tcp)

Reality PublicKey / PBK : ${REALITY_PUBLIC}
Short ID #1             : ${SHORT_ID_1}
Short ID #2             : ${SHORT_ID_2}

Self-steal target:
127.0.0.1:${SELF_PORT}

${warp_line}
============================================================
EOF
    chmod 600 "$WORK/CLIENT.txt"
}

write_check_sh() {
    cat > "$WORK/check.sh" <<EOF
#!/usr/bin/env bash
set -u

echo "===== REMNAWAVE NODE ====="
docker ps --filter name=${CONTAINER_NAME} \\
  --format 'table {{.Names}}\\t{{.Status}}\\t{{.Image}}' || true

echo
echo "===== PORTS ====="
ss -lntp | grep -E ':${VLESS_PORT} |127\\.0\\.0\\.1:${SELF_PORT}|:${NODE_PORT} ' || true

echo
echo "===== NGINX ====="
command -v nginx >/dev/null 2>&1 && nginx -t 2>&1 || echo "nginx не установлен (режим SNI)"

echo
echo "===== NODE LOG ====="
docker logs ${CONTAINER_NAME} --tail=80 2>&1 || true
EOF
    chmod 700 "$WORK/check.sh"
}

summary() {
    if [[ "$ROLE" == "ru" ]]; then
        summary_ru
    else
        summary_eu
    fi
    summary_masking_note
    summary_footer
}

summary_ru() {
    echo
    echo "============================================================"
    echo " RU-BRIDGE: ПОДГОТОВКА ЗАВЕРШЕНА"
    echo "============================================================"
    echo
    echo "Проверено:"
    echo "  [OK] Remnawave Node API :${NODE_PORT}"
    if [[ "$USE_SELFSTEAL" == "1" ]]; then
        echo "  [OK] self-steal nginx 127.0.0.1:${SELF_PORT}, внешний 443 свободен"
    else
        echo "  [OK] Reality target: ${REALITY_TARGET}"
    fi
    echo "  [OK] цепочка RU -> EU: exit ${EU_EXIT_IP:-unknown} (${EU_LOC:-unknown})"
    echo
    echo "Файлы:"
    echo "  ${WORK}/final-config.json   — профиль для Remnawave (содержит секреты)"
    echo "  ${WORK}/CLIENT.txt          — параметры Host / клиента"
    echo "  ${WORK}/check.sh            — диагностика"
    echo
    echo "Что сделать в панели Remnawave:"
    echo "  1) Nodes -> Create: адрес ${SERVER_IP:-<IP этого сервера>}, порт ${NODE_PORT}"
    echo "  2) Config Profiles -> Create: вставь содержимое final-config.json,"
    echo "     назначь профиль этой ноде, выбери inbound ${ENTRY_TAG}"
    echo "  3) Internal Squad: включи inbound ${ENTRY_TAG}, добавь пользователей"
    echo "  4) Hosts -> Create: данные из CLIENT.txt"
    echo
    echo "После применения профиля Xray займёт внешний TCP/${VLESS_PORT}:"
    echo "  ss -lntp | grep ':${VLESS_PORT} '     # ожидается rw-core"
    echo
    echo "Совет по безопасности (на EU-ноде): пускать на порт выхода только"
    echo "этот сервер, чтобы EU-нода не светилась в интернете:"
    echo "  ufw allow from ${SERVER_IP:-<IP_RU>} to any port $(tool get "$LINK_JSON" port) proto tcp"
    echo "  (не закрой при этом доступ панели к Node API port EU-ноды)"
    echo
    echo "ВАЖНО: проверяй по МОБИЛЬНОЙ сети без Wi-Fi — по Wi-Fi белые списки не видны."
}

summary_eu() {
    echo
    echo "============================================================"
    echo " EU-EXIT: ПОДГОТОВКА ЗАВЕРШЕНА"
    echo "============================================================"
    echo
    echo "Проверено:"
    echo "  [OK] Remnawave Node API :${NODE_PORT}"
    echo "  [OK] self-steal nginx 127.0.0.1:${SELF_PORT}, внешний 443 свободен"
    if [[ "$WARP_ENABLED" == "1" ]]; then
        echo "  [OK] WARP test: warp=on, exit ${WARP_EXIT_IP:-unknown} (${WARP_LOC:-unknown})"
    else
        echo "  [OK] Выход настроен как DIRECT (без WARP)"
    fi
    echo
    echo "Файлы:"
    echo "  ${WORK}/final-config.json   — профиль для Remnawave (содержит секреты)"
    echo "  ${WORK}/CLIENT.txt          — параметры для сервисного пользователя"
    echo "  ${WORK}/check.sh            — диагностика"
    echo
    echo "Что сделать в панели Remnawave:"
    echo "  1) Nodes -> Create: адрес ${SERVER_IP:-<IP этого сервера>}, порт ${NODE_PORT}"
    echo "  2) Config Profiles -> Create: вставь содержимое final-config.json,"
    echo "     назначь профиль этой ноде"
    echo "  3) Создай сервисного пользователя на inbound ${ENTRY_TAG}"
    echo "     (без лимита трафика, дата окончания далеко в будущем)"
    echo "  4) Скопируй его vless://-ссылку — она понадобится RU-скрипту"
    echo
    echo "После применения профиля Xray займёт внешний TCP/${VLESS_PORT}:"
    echo "  ss -lntp | grep ':${VLESS_PORT} '     # ожидается rw-core"
    echo
    echo "Совет по безопасности: пускать на этот порт только IP RU-ноды(-нод),"
    echo "чтобы EU-нода не светилась в интернете для посторонних:"
    echo "  ufw allow from <IP_RU_НОДЫ> to any port ${VLESS_PORT} proto tcp"
    echo "  (не закрой при этом доступ панели к Node API port этой ноды)"
}

summary_masking_note() {
    echo
    echo "------------------------------------------------------------"
    echo "О маскировке под правила хостинга"
    echo "------------------------------------------------------------"
    echo "Сделано:"
    echo "  - контейнер и hostname называются '${CONTAINER_NAME}', а не remnanode"
    echo "  - локальный docker-тег образа: не содержит 'remnawave/node'"
    echo "Не сделано автоматически: имя процесса xray ВНУТРИ контейнера"
    echo "(его видно только через 'docker exec ${CONTAINER_NAME} ps', снаружи"
    echo "контейнера через обычный host 'ps' его и так не видно, т.к. у"
    echo "контейнера свой PID namespace). Чтобы переименовать сам процесс,"
    echo "сначала нужно посмотреть, как именно его запускает образ:"
    echo
    echo "  docker exec ${CONTAINER_NAME} sh -c 'cat /entrypoint.sh 2>/dev/null; ps aux'"
    echo
    echo "Пришли вывод — соберу безопасное переименование под конкретный"
    echo "entrypoint образа. Делать это вслепую я не стал: неверный путь к"
    echo "бинарнику в команде запуска уронит ноду."
    echo
    echo "И главное: переименование процесса не отменяет нарушение правил"
    echo "хостинга, если VPN как сервис запрещён в AUP — оно лишь прячет"
    echo "факт от беглой проверки по имени процесса/образа. Правила хостинга"
    echo "стоит прочитать отдельно, я их не проверял."
    echo "============================================================"
    echo
}

summary_footer() {
    if confirm "Показать final-config.json сейчас (для копирования в панель)?" n; then
        echo
        tool show "$WORK/final-config.json"
        echo
    else
        echo "Безопасный просмотр (секреты скрыты):"
        echo "  python3 ${TOOL} show ${WORK}/final-config.json --hide"
        echo "Полный текст для панели:"
        echo "  cat ${WORK}/final-config.json"
    fi
}

main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            -h|--help)
                print_usage
                exit 0
                ;;
            --version)
                echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"
                exit 0
                ;;
            --no-update)
                UPDATE_CHECK=0
                ;;
        esac
    done

    preflight
    write_tool
    check_for_update
    banner
    ask_questions
    check_dns_if_needed
    install_deps
    install_docker
    install_node
    gen_reality
    check_sni_target
    if [[ "$USE_SELFSTEAL" == "1" ]]; then
        setup_selfsteal
    fi

    if [[ "$ROLE" == "ru" ]]; then
        test_eu_exit
    else
        if [[ "$WARP_ENABLED" == "1" ]]; then
            install_wgcf
            register_warp_and_build_outbound
            test_warp_exit
        else
            blue "WARP отключён, выход настроен как DIRECT."
        fi
    fi

    build_final_config
    write_outputs
    summary
}

main "$@"
