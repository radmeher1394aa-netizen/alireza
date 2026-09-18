#!/usr/bin/env bash
# alireza Panel + AdGuard Home installer
# Target: Debian/Ubuntu, systemd, 1 vCPU / 1 GB RAM friendly.
# Keeps the upstream Nova runtime intact; adds AdGuard Home as a separate service.
set -Eeuo pipefail
umask 022

BRAND="alireza"
NOVA_INSTALLER="https://raw.githubusercontent.com/IRNova/Nova-Server/main/nova-node.sh"
ADGUARD_INSTALLER="https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh"
ADG_DIR="/opt/AdGuardHome"
ADG_BIN="$ADG_DIR/AdGuardHome"
STATE_DIR="/var/lib/alireza-installer"
LOG="/var/log/alireza-install.log"

c0=$'\033[0m'; cg=$'\033[32m'; cy=$'\033[33m'; cr=$'\033[31m'; cc=$'\033[36m'
say(){ printf '%s==>%s %s\n' "$cc" "$c0" "$*"; }
ok(){ printf '%sOK%s  %s\n' "$cg" "$c0" "$*"; }
warn(){ printf '%s!!%s  %s\n' "$cy" "$c0" "$*" >&2; }
die(){ printf '%sERROR%s %s\n' "$cr" "$c0" "$*" >&2; exit 1; }

trap 'rc=$?; warn "Installation stopped at line $LINENO (exit $rc). See $LOG"; exit $rc' ERR
mkdir -p "$STATE_DIR"
touch "$LOG"
exec > >(tee -a "$LOG") 2>&1

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash install.sh"
command -v systemctl >/dev/null 2>&1 || die "systemd is required."
command -v apt-get >/dev/null 2>&1 || die "Only Debian/Ubuntu are supported."

export DEBIAN_FRONTEND=noninteractive

wait_apt(){
  local n=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
        /var/cache/apt/archives/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
    [ "$n" -eq 0 ] && say "Waiting for apt/dpkg..."
    sleep 3; n=$((n+3))
    [ "$n" -lt 300 ] || die "apt/dpkg stayed locked for 5 minutes."
  done
}

install_prereqs(){
  wait_apt
  say "Installing prerequisites"
  apt-get update -y
  apt-get install -y curl ca-certificates tar gzip unzip psmisc iproute2 procps python3
  ok "Prerequisites ready"
}

ensure_swap(){
  local mem swap
  mem="$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)"
  swap="$(awk '/SwapTotal/{printf "%d",$2/1024}' /proc/meminfo)"
  if [ "$mem" -le 1200 ] && [ "$swap" -lt 768 ]; then
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx '/swapfile'; then
      ok "Swap already active"
      return
    fi
    if [ -e /swapfile ]; then
      warn "/swapfile exists but is not active; leaving it untouched."
      return
    fi
    say "Low-memory VPS detected (${mem} MB); creating 1 GB swap"
    if fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none; then
      chmod 600 /swapfile
      mkswap /swapfile >/dev/null
      if swapon /swapfile; then
        grep -qE '^/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        touch "$STATE_DIR/swap-created"
        sysctl -w vm.swappiness=10 >/dev/null || true
        cat >/etc/sysctl.d/99-alireza-lowmem.conf <<'EOF'
vm.swappiness=10
EOF
        ok "1 GB swap enabled"
      else
        rm -f /swapfile
        warn "Provider does not allow swap; continuing without it."
      fi
    fi
  fi
}

install_nova(){
  if systemctl cat nova-agent >/dev/null 2>&1 && [ -d /opt/nova-node-agent ]; then
    ok "Core panel already installed; preserving current installation"
    return
  fi
  say "Installing the upstream panel core"
  local f="$STATE_DIR/nova-node.sh"
  curl -fL --connect-timeout 15 --max-time 600 --retry 3 "$NOVA_INSTALLER" -o "$f"
  chmod 700 "$f"
  # Keep upstream install behavior. User can answer its domain/path questions.
  bash "$f"
  ok "Core panel installed"
}

port53_report(){
  ss -lntup 2>/dev/null | awk '$5 ~ /:53$/ {print}' || true
}

free_port53(){
  say "Preparing TCP/UDP port 53 for AdGuard Home"

  # systemd-resolved's local stub commonly owns 127.0.0.53:53.
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    if ss -lntup 2>/dev/null | grep -E '127\.0\.0\.53%?[^ ]*:53|127\.0\.0\.53:53' >/dev/null; then
      say "Disabling systemd-resolved stub listener (resolver service stays enabled)"
      mkdir -p /etc/systemd/resolved.conf.d
      cat >/etc/systemd/resolved.conf.d/99-alireza-adguard.conf <<'EOF'
[Resolve]
DNSStubListener=no
EOF
      systemctl restart systemd-resolved || true

      # With the stub disabled, use resolved's real resolver file when available.
      if [ -e /run/systemd/resolve/resolv.conf ]; then
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
      fi
    fi
  fi

  # dnsmasq is safe to stop only if it is actually the process occupying :53.
  if ss -lntup 2>/dev/null | grep ':53 ' | grep -qi 'dnsmasq'; then
    say "Port 53 is occupied by dnsmasq; disabling it so AdGuard can bind"
    systemctl disable --now dnsmasq 2>/dev/null || true
  fi

  # Never kill arbitrary DNS services. That could break VPN/networking.
  if ss -lntup 2>/dev/null | grep -E '(:53[[:space:]])' | grep -v -i 'AdGuardHome' >/dev/null; then
    warn "Port 53 is still occupied:"
    port53_report
    die "Free port 53 manually, then rerun install.sh. Unknown services are not killed automatically."
  fi
  ok "Port 53 is available"
}

open_firewall(){
  say "Opening DNS port 53 where a host firewall is active"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1 | grep -qi active; then
    ufw allow 53/tcp >/dev/null
    ufw allow 53/udp >/dev/null
    ok "UFW: TCP/UDP 53 allowed"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-service=dns >/dev/null
    firewall-cmd --reload >/dev/null
    ok "firewalld: DNS allowed"
  fi

  # Do not flush/replace raw nftables/iptables rules: preserving an operator's
  # security policy is safer than guessing at rule ordering.
}

install_adguard(){
  if [ -x "$ADG_BIN" ]; then
    ok "AdGuard Home already installed"
    return
  fi
  say "Installing official AdGuard Home"
  local f="$STATE_DIR/adguard-install.sh"
  curl -fL --connect-timeout 15 --max-time 600 --retry 3 "$ADGUARD_INSTALLER" -o "$f"
  chmod 700 "$f"
  sh "$f" -v
  [ -x "$ADG_BIN" ] || die "AdGuard Home installer finished but binary was not found."
  ok "AdGuard Home installed"
}

configure_adguard_dns(){
  local y="$ADG_DIR/AdGuardHome.yaml"
  say "Configuring AdGuard Home automatically"
  systemctl stop AdGuardHome 2>/dev/null || "$ADG_BIN" -s stop 2>/dev/null || true
  if [ ! -s "$y" ]; then timeout 5 "$ADG_BIN" --no-check-update -w "$ADG_DIR" -c "$y" >/dev/null 2>&1 || true; fi
  [ -s "$y" ] || die "Could not create AdGuardHome.yaml"
  cp -a "$y" "$y.before-alireza.$(date +%Y%m%d%H%M%S)"
  python3 - "$y" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p,encoding="utf-8").read()
if re.search(r'(?m)^http:\s*$',s):
 m=re.search(r'(?ms)^http:\s*\n(?P<b>(?:^[ \t]+.*\n?)*)',s); x=m.group('b')
 if re.search(r'(?m)^[ \t]+address:',x): x=re.sub(r'(?m)^([ \t]+)address:.*$',r'\1address: 127.0.0.1:3000',x,count=1)
 else: x='  address: 127.0.0.1:3000\n'+x
 s=s[:m.start('b')]+x+s[m.end('b'):]
else:
 s=re.sub(r'(?m)^bind_host:.*$','bind_host: 127.0.0.1',s,count=1)
 s=re.sub(r'(?m)^bind_port:\s*\d+.*$','bind_port: 3000',s,count=1)
s=re.sub(r'(?ms)^users:\s*\n(?:^[ \t]+.*\n?)*?(?=^[A-Za-z_])','users: []\n',s,count=1)
if not re.search(r'(?m)^users:',s): s+='\nusers: []\n'
m=re.search(r'(?ms)^dns:\s*\n(?P<b>(?:^[ \t]+.*\n?)*)',s)
if not m: raise SystemExit("dns section missing")
x=m.group('b')
if re.search(r'(?m)^[ \t]+bind_hosts:\s*$',x): x=re.sub(r'(?ms)^([ \t]+)bind_hosts:\s*\n(?:\1[ \t]+-.*\n)*',r'\1bind_hosts:\n\1  - 0.0.0.0\n',x,count=1)
elif re.search(r'(?m)^[ \t]+bind_host:',x): x=re.sub(r'(?m)^([ \t]+)bind_host:.*$',r'\1bind_host: 0.0.0.0',x,count=1)
else: x='  bind_hosts:\n    - 0.0.0.0\n'+x
if re.search(r'(?m)^[ \t]+port:',x): x=re.sub(r'(?m)^([ \t]+)port:\s*\d+.*$',r'\1port: 53',x,count=1)
else: x='  port: 53\n'+x
s=s[:m.start('b')]+x+s[m.end('b'):]
open(p,'w',encoding='utf-8').write(s)
PY
  systemctl start AdGuardHome 2>/dev/null || "$ADG_BIN" -s start
  sleep 2
  systemctl is-active --quiet AdGuardHome || die "AdGuard Home failed to start"
  ss -lnup 2>/dev/null | grep -E ':53[[:space:]]' | grep -qi AdGuard || die "AdGuard is not listening on UDP :53"
  ok "AdGuard ready: DNS :53; native UI localhost :3000; no separate account"
}

lowmem_limits(){
  # Guard rails, not aggressive throttling. MemoryMax is intentionally NOT used:
  # hard caps can kill DNS/proxy processes under legitimate load.
  mkdir -p /etc/systemd/system/AdGuardHome.service.d
  cat >/etc/systemd/system/AdGuardHome.service.d/10-alireza-lowmem.conf <<'EOF'
[Service]
OOMScoreAdjust=-250
Restart=on-failure
RestartSec=3
EOF
  systemctl daemon-reload
  systemctl restart AdGuardHome 2>/dev/null || true
}

install_helpers(){
  cat >/usr/local/bin/alireza-status <<'EOF'
#!/usr/bin/env bash
echo "=== alireza Panel ==="
printf "%-18s %s\n" "Panel core:" "$(systemctl is-active nova-agent 2>/dev/null || echo unknown)"
printf "%-18s %s\n" "Xray:" "$(systemctl is-active xray 2>/dev/null || echo inactive)"
printf "%-18s %s\n" "AdGuard Home:" "$(systemctl is-active AdGuardHome 2>/dev/null || echo inactive)"
echo
echo "DNS listeners:"
ss -lntup 2>/dev/null | awk '$5 ~ /:53$/ {print}'
echo
free -h
EOF
  chmod 755 /usr/local/bin/alireza-status
}

summary(){
  local ip
  ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
  echo
  echo "============================================================"
  echo " alireza Panel installation finished"
  echo "============================================================"
  echo " Server IP:       ${ip:-unknown}"
  echo " DNS:             ${ip:-SERVER_IP}:53 TCP/UDP"
  echo " AdGuard service: $(systemctl is-active AdGuardHome 2>/dev/null || echo unknown)"
  echo " Core service:    $(systemctl is-active nova-agent 2>/dev/null || echo unknown)"
  echo " Status command:  alireza-status"
  echo " Install log:     $LOG"
  echo
  echo "Note: the upstream core's closed/prebuilt UI is intentionally not binary-patched."
  echo "That avoids breaking updates or corrupting the panel. The alireza name is used"
  echo "for this integration layer and helper commands."
  echo "============================================================"
}

main(){
  install_prereqs
  ensure_swap
  install_nova
  free_port53
  open_firewall
  install_adguard
  configure_adguard_dns
  lowmem_limits
  install_helpers
  summary
}
main "$@"
