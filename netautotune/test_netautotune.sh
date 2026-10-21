#!/usr/bin/env bash
# Тесты netautotune.sh (чистый bash, root не нужен, в систему ничего не пишут).
# Запуск:  bash test_netautotune.sh [путь/к/netautotune.sh]
set -u
SCRIPT=$(readlink -f "${1:-$(dirname "$0")/netautotune.sh}")
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n      ожидалось: [%s]\n      получено:  [%s]\n' "$1" "$2" "$3"; }
eq()  { [[ "$2" == "$3" ]] && ok || bad "$1" "$2" "$3"; }
ok_cmd()   { if "${@:2}"; then ok; else bad "$1" "успех" "код $?"; fi; }
fail_cmd() { if "${@:2}"; then bad "$1" "ошибка" "успех"; else ok; fi; }

# --- подключаем скрипт как библиотеку, состояние — во временной папке
export STATE_DIR="$TMP/state" CONF_FILE=/nonexistent DRY_RUN=1
source "$SCRIPT"
IFACE=lo; NIC_SPEED_CAP=0; PORT_CAP_MBIT=0
init_state

now=$(date +%s); DAY=86400
reset() { : > "$STATE"; : > "$LOG"; PORT_CAP_MBIT=0; }
log_add() { echo "$1 $2 $3" >> "$LOG"; }            # epoch тип значение

# ------------------------------------------------------------------ to_tier / clamp
for pair in "0:100" "100:100" "101:150" "3437:4000" "6000:6000" "6001:10000" "99999:10000"; do
    eq "to_tier ${pair%%:*}" "${pair##*:}" "$(to_tier "${pair%%:*}")"
done
eq "clamp снизу" 10  "$(clamp 1 10 20)"
eq "clamp сверху" 20 "$(clamp 99 10 20)"
eq "clamp внутри" 15 "$(clamp 15 10 20)"

# ---------------------------------------------------------------- calc_conntrack
eq "conntrack 1967МБ" 126976  "$(calc_conntrack 1967)"
eq "conntrack минимум" 32768  "$(calc_conntrack 100)"
eq "conntrack максимум" 2097152 "$(calc_conntrack 1000000)"

# ---------------------------------------------------------------------- envelope
reset
eq "envelope пустой журнал" 0 "$(envelope P 7)"
log_add $((now-3600)) P 300; log_add $((now-DAY-3600)) P 500; log_add $((now-2*DAY-3600)) P 400
eq "envelope <4 дней = максимум" 500 "$(envelope P 7)"
log_add $((now-3*DAY-3600)) P 9000
eq "envelope >=4 дней отсекает выброс (2-й по величине)" 500 "$(envelope P 7)"
log_add $((now-20*DAY)) P 99999
eq "envelope игнорирует записи вне окна" 500 "$(envelope P 7)"
reset; log_add $((now-100)) A 2000; log_add $((now-100)) P 50
eq "envelope не смешивает типы" 50 "$(envelope P 7)"
eq "max_recent A" 2000 "$(max_recent A 30)"
log_add $((now-40*DAY)) A 9999
eq "max_recent A игнорирует старое" 2000 "$(max_recent A 30)"

# -------------------------------------------------------------------- rtt_design
reset
for i in $(seq 1 11); do log_add $((now-i*100)) R 20; done
eq "rtt_design <12 замеров = 0" 0 "$(rtt_design)"
log_add $((now-5)) R 20
eq "rtt_design 12 одинаковых" 20 "$(rtt_design)"
reset
for i in $(seq 1 20); do log_add $((now-i*100)) R $((60+i*5)); done
eq "rtt_design p80 из 65..160" 140 "$(rtt_design)"
reset
for i in $(seq 1 14); do log_add $((now-i*100)) R 30; done
for i in $(seq 1 3);  do log_add $((now-i*50))  R 171724; done
eq "rtt_design игнорирует выбросы >2000 мс" 30 "$(rtt_design)"

# ----------------------------------------------------------------------- decide
reset; echo "tier=10000" > "$STATE"; log_add $((now-100)) A 1000
decide 1
eq "decide: вниз сразу нельзя" 10000 "$TIER"
ok_cmd "decide: фиксирует down_since" test "$(state_get down_since)" -gt 0
state_set down_since $((now - DOWN_CONFIRM_SEC - 10)); decide 1
eq "decide: вниз после подтверждения" 1000 "$TIER"
eq "decide: down_since сброшен" 0 "$(state_get down_since)"
reset; echo "tier=1000" > "$STATE"; log_add $((now-100)) A 5000
decide 1; eq "decide: вверх сразу" 6000 "$TIER"
reset; log_add $((now-100)) A 5000; PORT_CAP_MBIT=500
decide 0; eq "decide: потолок по тарифу" 600 "$TIER"
reset; decide 0; eq "decide: без данных = DEFAULT_MBIT" 1000 "$TIER"; eq "decide: RTT по умолчанию" 100 "$RTT"
reset; for i in $(seq 1 15); do log_add $((now-i*100)) R 30; done; decide 0
eq "decide: RTT не ниже RTT_MIN_MS (40 -> 50)" 50 "$RTT"
reset; echo "tier=1000" > "$STATE"; log_add $((now-100)) A 1000; decide 1
eq "decide: тот же тир — down_since=0" 0 "$(state_get down_since)"

# ------------------------------------------------------------------ budget_ok
reset; TEST_BUDGET_GB=2
state_set month "$(date +%Y%m)"; state_set used_mb 2040
fail_cmd "budget: исчерпан" budget_ok
state_set used_mb 100;           ok_cmd   "budget: достаточно" budget_ok
state_set month 200001; state_set used_mb 2040
ok_cmd "budget: новый месяц сбрасывает" budget_ok
eq "budget: used_mb обнулён" 0 "$(state_get used_mb)"

# ------------------------------------------------------------ should_calibrate
TEST_BUDGET_GB=10; RECHECK_DAYS=14
reset;                                                      ok_cmd   "calibrate: первый запуск" should_calibrate
reset; state_set last_active $((now-DAY));                  fail_cmd "calibrate: свежий тест" should_calibrate
reset; state_set last_active $((now-20*DAY)); state_set tier 4000
ok_cmd "calibrate: старый тест, нода простаивает" should_calibrate
log_add $((now-100)) P 3000
fail_cmd "calibrate: старый тест, но нода занята" should_calibrate
reset; state_set last_attempt $((now-3600));               fail_cmd "calibrate: недавняя попытка (6ч)" should_calibrate
reset; state_set month "$(date +%Y%m)"; state_set used_mb 99999
fail_cmd "calibrate: бюджет исчерпан" should_calibrate

# -------------------------------------------------------------- парсер ss (flow_sample)
mk_ss() {  # $1 число сокетов, $2 rtt-шаблон (awk-выражение от i)
    echo "Recv-Q Send-Q Local Address:Port Peer Address:Port"
    awk -v n="$1" -v e="$2" 'BEGIN{for(i=1;i<=n;i++){ r=(e=="out"&&i==n)?171724:15+i; \
        printf "0 0 10.0.0.1:443 1.1.1.%d:5000\n\t bbr rtt:%s/1 bytes_acked:50000 delivery_rate 50Mbps bbr:(bw:%dMbps,mrtt:1)\n", i, r, 100+i}}'
    printf '0 0 127.0.0.1:80 127.0.0.1:5000\n\t cubic rtt:0.1/0 bytes_acked:99999999 delivery_rate 40Gbps\n'
}
ss() { cat "$TMP/ss.txt"; }
mk_ss 12 ok  > "$TMP/ss.txt"; out=$(flow_sample)
eq "ss: p90 RTT при 12 сокетах" "26 112" "$out"            # 11-е из 16..27 (ближайший ранг), max bw=112 (loopback 40Gbps исключён)
mk_ss 5 ok   > "$TMP/ss.txt"; out=$(flow_sample)
eq "ss: <10 сокетов -> RTT не считаем" "- 105" "$out"
mk_ss 12 out > "$TMP/ss.txt"; out=$(flow_sample); rtt=${out%% *}
ok_cmd "ss: выброс 171724 не попадает в RTT" test "$rtt" -lt 2000
unset -f ss

# ----------------------------------------------------------------- sample_tick
RX_NOW=0; TX_NOW=0; T_NOW=0
read_bytes() { echo "$RX_NOW $TX_NOW"; }
now_ms() { echo "$T_NOW"; }
SAMPLE_SEC=5; PEAK=0; PRX=""; PTX=""; PT=0
RX_NOW=0;          T_NOW=1000;  sample_tick                 # первый тик — только база
RX_NOW=625000000;  T_NOW=6000;  sample_tick                 # 625 МБ за 5 с = 1000 Мбит
eq "sample_tick: 1000 Мбит за 5 с" 1000 "$PEAK"
RX_NOW=$((625000000 + 625000000)); T_NOW=36000; sample_tick # тик задержался до 30 с -> выбросить
eq "sample_tick: задержка >3x не завышает" 1000 "$PEAK"
TX_NOW=1250000000; RX_NOW=$((625000000 + 625000000)); T_NOW=41000; sample_tick   # tx 1.25 ГБ/5 с = 2000 Мбит
eq "sample_tick: берёт max(rx,tx)" 2000 "$PEAK"
unset -f read_bytes now_ms; source "$SCRIPT"                # вернуть настоящие функции

# --------------------------------------------------------------------- render
render_val() { grep -E "^$1 *=" <<<"$2" | head -1 | sed 's/^[^=]*= *//'; }
for combo in "100 50" "1000 100" "4000 100" "10000 250" "6000 300"; do
    set -- $combo; out=$(DISABLE_IPV6=1 ICMP_IGNORE=0 render "$1" "$2")
    rmax=$(render_val net.core.rmem_max "$out"); wmax=$(render_val net.core.wmem_max "$out")
    tmax=$(render_val net.ipv4.tcp_rmem "$out"); tmax=${tmax##* }
    ok_cmd "render $combo: rmem_max кратен 1 МиБ" test $((rmax % 1048576)) -eq 0
    ok_cmd "render $combo: rmem_max >= 8 МиБ"     test "$rmax" -ge 8388608
    ok_cmd "render $combo: rmem_max <= 256 МиБ"   test "$rmax" -le 268435456
    eq     "render $combo: wmem_max = rmem_max"   "$rmax" "$wmax"
    eq     "render $combo: tcp_rmem max = rmem_max" "$rmax" "$tmax"
    ok_cmd "render $combo: somaxconn <= 65535"    test "$(render_val net.core.somaxconn "$out")" -le 65535
done
out=$(render 4000 100)
fail_cmd "render: нет read-only nf_conntrack_buckets" grep -q 'nf_conntrack_buckets' <<<"$out"
fail_cmd "render: ICMP по умолчанию не блокируется"   grep -q 'icmp_echo_ignore_all' <<<"$out"
ok_cmd   "render: ICMP_IGNORE=1 добавляет строку"     grep -q 'icmp_echo_ignore_all' < <(ICMP_IGNORE=1 render 4000 100)
fail_cmd "render: DISABLE_IPV6=0 без ipv6-строк"      grep -q 'disable_ipv6' < <(DISABLE_IPV6=0 render 4000 100)
ok_cmd   "render: conntrack-ключи с префиксом '-'"    grep -q '^-net.netfilter.nf_conntrack_max' <<<"$out"
eq "render: тир растёт -> буфер не уменьшается" 1 "$(a=$(render_val net.core.rmem_max "$(render 1000 100)"); b=$(render_val net.core.rmem_max "$(render 4000 100)"); (( b >= a )) && echo 1 || echo 0)"
ipv6_needed() { return 0; }
ok_cmd "render: IPv6 не отключается, если по нему управление" grep -q 'IPv6 НЕ отключён' < <(DISABLE_IPV6=1 render 4000 100)
fail_cmd "render: ... и нет строк disable_ipv6"               grep -q '^net.ipv6.conf.all.disable_ipv6' < <(DISABLE_IPV6=1 render 4000 100)
ipv6_needed() { return 1; }
ok_cmd "render: IPv6 отключается, если не нужен"              grep -q '^net.ipv6.conf.all.disable_ipv6 = 1' < <(DISABLE_IPV6=1 render 4000 100)

# ------------------------------------------------- гонка состояния (демон vs CLI)
if command -v flock >/dev/null; then
    # детерминированно: пока кто-то держит замок, запись обязана ждать (иначе демон и CLI затрут друг друга)
    held() { ( flock 9; sleep 1.5 ) 9>>"$LOCK" & sleep 0.3; }     # держатель замка на ~1.2 с после паузы
    ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
    reset; held; t=$(date +%s%N); state_set k v; e=$(ms "$t"); wait
    ok_cmd "state_set ждёт замок (>=800 мс)"  test "$e" -ge 800
    eq     "state_set: значение записано"      "k=v" "$(cat "$STATE")"
    reset; held; t=$(date +%s%N); add_sample P 1; e=$(ms "$t"); wait
    ok_cmd "add_sample ждёт замок (>=800 мс)" test "$e" -ge 800
    reset; held; t=$(date +%s%N); prune_log; e=$(ms "$t"); wait
    ok_cmd "prune_log ждёт замок (>=800 мс)"  test "$e" -ge 800
    # и стресс-прогон: ничего не теряется
    reset
    w() { for i in $(seq 1 120); do state_set "$1" "$i"; done; }
    w daemon_key & w cli_key & wait
    eq "state_set: оба ключа выживают при параллельной записи" "cli_key=120 daemon_key=120" \
       "$(sort -u "$STATE" | tr '\n' ' ' | sed 's/ $//')"
    reset
    w2() { for i in $(seq 1 100); do add_sample P "$i"; done; }
    w2 & w2 & wait
    eq "add_sample: ни одна запись не потеряна" 200 "$(wc -l < "$LOG")"
else
    echo "SKIP: flock не найден, тесты блокировки пропущены"
fi

# ---------------------------------------------------------------------- итог
echo; echo "Итого: $PASS успешно, $FAIL провалено"
(( FAIL == 0 ))
