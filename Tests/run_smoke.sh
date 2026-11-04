#!/bin/bash
# Compiles the proxy for macOS and exercises it end to end with curl.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$work"' EXIT

swiftc -swift-version 5 "$root/PuenteWiFi/ProxyServer.swift" "$root/PuenteWiFi/PortalDetector.swift" \
  "$root/Tests/ProxySmoke/main.swift" -o "$work/smoke" || exit 1

mkdir "$work/www" && echo "hola-origen" > "$work/www/index.txt"
head -c 5000000 /dev/urandom > "$work/www/big.bin"
(cd "$work/www" && exec python3 -m http.server 18081 --bind 127.0.0.1 >/dev/null 2>&1) &
"$work/smoke" > "$work/smoke.log" 2>&1 &
smoke_pid=$!
for _ in $(seq 1 50); do
  grep -q 'open: running' "$work/smoke.log" && grep -q 'guarded: running' "$work/smoke.log" && break
  kill -0 "$smoke_pid" 2>/dev/null || break
  sleep 0.2
done
for _ in $(seq 1 50); do curl -s -o /dev/null --max-time 1 http://127.0.0.1:18081/index.txt && break; sleep 0.2; done
if ! kill -0 "$smoke_pid" 2>/dev/null; then cat "$work/smoke.log"; echo "FALLA pruebas unitarias"; exit 1; fi
echo "pruebas unitarias correctas: $(grep -c '^ok' "$work/smoke.log")"

failures=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then echo "ok    $name"; else echo "FALLA $name: esperado '$expected', obtenido '$actual'"; failures=$((failures + 1)); fi
}
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$@"; }

auth="wifi:secreto"
open=http://127.0.0.1:18080
guarded=http://127.0.0.1:18082
origin=http://127.0.0.1:18081

check "sin credenciales da 407" 407 "$(code -x $open $origin/index.txt)"
check "contraseña incorrecta da 407" 407 "$(code -x $open -U wifi:mala $origin/index.txt)"
check "HTTP por proxy" hola-origen "$(curl -s --max-time 20 -x $open -U $auth $origin/index.txt)"
check "POST por proxy" 501 "$(code -x $open -U $auth -d 'a=1' $origin/index.txt)"

curl -s --max-time 30 -x $open -U $auth -o "$work/big.get" $origin/big.bin
check "descarga de 5 MB por HTTP intacta" "$(shasum "$work/www/big.bin" | cut -d' ' -f1)" "$(shasum "$work/big.get" | cut -d' ' -f1)"

curl -s --max-time 30 -p -x $open -U $auth -o "$work/big.tunnel" $origin/big.bin
check "descarga de 5 MB por CONNECT intacta" "$(shasum "$work/www/big.bin" | cut -d' ' -f1)" "$(shasum "$work/big.tunnel" | cut -d' ' -f1)"

check "destino localhost bloqueado" 403 "$(code -x $guarded -U $auth http://localhost:18081/index.txt)"
check "IP privada bloqueada" 403 "$(code -x $guarded -U $auth $origin/index.txt)"
check "IP decimal bloqueada al conectar" 403 "$(code -x $guarded -U $auth http://2130706433:18081/index.txt)"
check "CONNECT privado bloqueado" 403 "$(curl -s -o /dev/null -w '%{http_connect}' --max-time 20 -p -x $guarded -U $auth $origin/index.txt)"
check "puerto cerrado da 502" 502 "$(code -x $open -U $auth http://127.0.0.1:1/)"

check "página local" 200 "$(code $open/)"
check "archivo PAC" 'function FindProxyForURL(url, host) { return "PROXY 127.0.0.1:18080"; }' "$(curl -s --max-time 5 $open/proxy.pac)"
check "Host malicioso no se refleja" 0 "$(curl -s --max-time 5 -H 'Host: "><script>' $open/ | grep -c '<script>')"
check "ruta desconocida da 404" 404 "$(code $open/nada)"
check "solicitud basura da 400" 400 "$(printf 'BASURA\r\n\r\n' | nc -w 3 127.0.0.1 18080 | head -1 | cut -d' ' -f2)"

check "HTTPS real por proxy" 200 "$(code -x $guarded -U $auth https://example.com/)"

echo "fallos: $failures"
[ "$failures" -eq 0 ]
