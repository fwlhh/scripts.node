#!/usr/bin/env bash
#
# netautotune — адаптивный sysctl для сетевых нод, который почти не тратит трафик.
#
# Идея:
#   1. Основной источник данных — ПАССИВНЫЙ (бесплатный): реальная пропускная способность
#      интерфейса (/proc/net/dev), реальные RTT клиентов и скорость потоков (ss -ti).
#   2. Активный speedtest — редкий и маленький: только если нода простаивает и
#      пассивные данные ничего не доказывают. Тест идёт «лесенкой» 64 МБ -> x3 -> ...
#      и останавливается, как только замер стал достаточно длинным. Есть месячный бюджет.
#   3. Результат — не точная скорость, а ТИР (ступень 100/150/250/.../10000 Мбит).
#      Буферы — это потолки, а не выделенная память, поэтому точность до процента не нужна.
#      Берётся верхняя огибающая за 7 дней (скорость скачет из-за соседей — нас интересует
#      то, что нода МОЖЕТ), вверх — сразу, вниз — только после 24 ч подтверждения.
#   4. Расчётный RTT — реальный p80 по клиентам, а не RTT до одного speedtest-сервера.
#
# Команды:  install | uninstall | daemon | eval | calibrate | status | render [tier rtt] | export
#
set -u
export LC_ALL=C

CONF_FILE=${CONF_FILE:-/etc/netautotune.conf}
STATE_DIR=${STATE_DIR:-/var/lib/netautotune}
OUT_FILE=${OUT_FILE:-/etc/sysctl.d/99-netautotune.conf}
CT_MODPROBE=${CT_MODPROBE:-/etc/modprobe.d/netautotune.conf}
BBR_MODLOAD=${BBR_MODLOAD:-/etc/modules-load.d/netautotune.conf}
DRY_RUN=${DRY_RUN:-0}
SELF_BIN=/usr/local/sbin/netautotune
UNIT_FILE=/etc/systemd/system/netautotune.service

# ------------------------- настройки по умолчанию (переопределяются в $CONF_FILE) ----
IFACE=""                    # пусто = определить автоматически
SAMPLE_SEC=5                # шаг пассивного замера скорости интерфейса
EVAL_SEC=600                # как часто пересчитывать (сек)
PORT_CAP_MBIT=0             # жёсткий потолок по тарифу, Мбит/с (0 = не задан)
NIC_SPEED_CAP=1             # учитывать /sys/class/net/IF/speed как потолок, если он известен
DEFAULT_MBIT=1000           # тир, пока нет никаких данных
DEFAULT_RTT_MS=100          # RTT, пока нет данных по клиентам
RTT_MIN_MS=40
RTT_MAX_MS=250
PASSIVE_HEADROOM_PCT=125    # запас над наблюдаемым пиком (пик != ёмкость канала)
PASSIVE_WINDOW_DAYS=7
RECHECK_DAYS=14             # как часто перепроверять активным тестом ТОЛЬКО простаивающую ноду
LOG_KEEP_DAYS=30
DOWN_CONFIRM_SEC=86400      # снижать тир только если «ниже» держится столько секунд
# --- бюджет активных тестов ---
TEST_BUDGET_GB=10           # максимум трафика на тесты в месяц
TEST_MAX_MB=1000            # потолок одного теста (лесенка 64 -> 192 -> 576 -> ... до этого значения)
TEST_PARALLEL=4
TEST_MAX_SEC=12             # потолок длительности одного раунда
TEST_PROVIDER="yandex"      # yandex = зонды Яндекс CDN (ссылки берутся из API); custom = только TEST_URLS
YANDEX_PROBES_API="https://yandex.ru/internet/api/v0/get-probes"
STATIC_MAX_MB=50            # размер статического файла-зонда (у Яндекса 50 МБ)
TEST_UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
# запасные/свои источники: либо шаблон с @BYTES@ (размер подставляется), либо ссылка на статический файл (качается через Range)
TEST_URLS=("https://speed.cloudflare.com/__down?bytes=@BYTES@")
# --- группа нод на одном хосте: лидер публикует `netautotune export`, остальные читают ---
PEER_URL=""
# --- опции ---
DISABLE_IPV6=1
ICMP_IGNORE=0               # 1 = не отвечать на ping (ломает мониторинг хостера, как защита почти бесполезно)

[[ -f $CONF_FILE ]] && . "$CONF_FILE"

TIERS=(100 150 250 400 600 1000 1500 2500 4000 6000 10000)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# ------------------------------------------------------------------ инициализация -----
detect_iface() {
    local i
    i=$(ip -o -4 route get 1.1.1.1 2>/dev/null | awk '{for(k=1;k<=NF;k++) if($k=="dev"){print $(k+1); exit}}')
    [[ -z $i ]] && i=$(awk -F'[: ]+' 'NR>2 && $2!="lo"{print $2; exit}' /proc/net/dev)
    echo "$i"
}

init_state() {
    mkdir -p "$STATE_DIR" 2>/dev/null
    STATE="$STATE_DIR/state"; LOG="$STATE_DIR/samples.log"
    touch "$STATE" "$LOG" 2>/dev/null
}

need_iface() {
    [[ -n $IFACE ]] || IFACE=$(detect_iface)
    [[ -n $IFACE ]] || { echo "Не удалось определить интерфейс, задайте IFACE= в $CONF_FILE" >&2; exit 1; }
}

state_get() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | tail -1; }
state_set() {
    grep -v "^$1=" "$STATE" > "$STATE.tmp" 2>/dev/null
    echo "$1=$2" >> "$STATE.tmp"; mv "$STATE.tmp" "$STATE"
}

# ----------------------------------------------------------- журнал наблюдений --------
# строки: <epoch> <тип> <значение>;  P = пассивный пик (Мбит, уже с запасом), A = активный замер (Мбит), R = RTT (мс)
add_sample() { echo "$(date +%s) $1 $2" >> "$LOG"; }
prune_log() {
    local cut=$(( $(date +%s) - LOG_KEEP_DAYS * 86400 ))
    awk -v c="$cut" '$1>=c' "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

# верхняя огибающая: максимумы по суткам, берём 2-й по величине (если дней >=4), иначе 1-й — устойчиво к выбросам
envelope() {  # $1 тип, $2 окно в днях
    local since=$(( $(date +%s) - $2 * 86400 ))
    awk -v t="$1" -v s="$since" '$2==t && $1>=s {d=int($1/86400); if($3>m[d]) m[d]=$3} END{for(d in m) print m[d]}' "$LOG" \
      | sort -rn | awk '{a[NR]=$1} END{ if(NR==0) print 0; else if(NR>=4) print a[2]; else print a[1] }'
}
max_recent() {  # $1 тип, $2 дней
    local since=$(( $(date +%s) - $2 * 86400 ))
    awk -v t="$1" -v s="$since" '$2==t && $1>=s && $3>m {m=$3} END{print m+0}' "$LOG"
}
rtt_design() {  # p80 по RTT-замерам за 7 дней; 0 если данных мало
    local since=$(( $(date +%s) - 7 * 86400 ))
    awk -v s="$since" '$2=="R" && $1>=s {print $3}' "$LOG" | sort -n \
      | awk '{a[NR]=$1} END{ if(NR<12){print 0; exit} i=int(NR*0.8); if(i<1)i=1; print a[i] }'
}

# ----------------------------------------------------------------- пассивные замеры ---
read_bytes() {  # "rx tx" байт интерфейса
    awk -v i="$IFACE" '{sub(/:/," ")} $1==i {print $2, $10}' /proc/net/dev
}

sample_tick() {
    local rx tx d1 d2 m
    read -r rx tx < <(read_bytes)
    [[ -n ${rx:-} ]] || return
    if [[ -n ${PRX:-} ]]; then
        d1=$(( rx - PRX )); d2=$(( tx - PTX ))
        (( d1 < 0 )) && d1=0; (( d2 < 0 )) && d2=0
        (( d2 > d1 )) && d1=$d2
        m=$(( d1 * 8 / SAMPLE_SEC / 1000000 ))
        (( m > PEAK )) && PEAK=$m
    fi
    PRX=$rx; PTX=$tx
}

# RTT и скорость потоков реальных клиентов (бесплатно, из ядра)
flow_sample() {  # печатает: "<rtt_p90_ms|-> <max_flow_mbit>"
    local out
    out=$(ss -tin state established 2>/dev/null | awk '
        function rate(s,  v){ v=s+0; if(s~/G/) v*=1000; else if(s~/K/) v/=1000; else if(s!~/M/) v/=1000000; return v }
        !/^[ \t]/ { peer=$4; next }
        {
            if (peer ~ /^(127\.|\[::1\])/) next
            rtt=0; vol=0; bw=0
            if (match($0,/ rtt:[0-9.]+/))            rtt=substr($0,RSTART+5,RLENGTH-5)+0
            if (match($0,/bytes_acked:[0-9]+/))      vol+=substr($0,RSTART+12,RLENGTH-12)
            if (match($0,/bytes_received:[0-9]+/))   vol+=substr($0,RSTART+15,RLENGTH-15)
            if (match($0,/delivery_rate [0-9.]+[KMG]?bps/)) { x=rate(substr($0,RSTART+14,RLENGTH-14)); if(x>bw) bw=x }
            if (match($0,/bbr:\(bw:[0-9.]+[KMG]?bps/))      { x=rate(substr($0,RSTART+8,RLENGTH-8));  if(x>bw) bw=x }
            if (rtt>0 && vol>=10000) print "R", rtt
            if (bw>mx) mx=bw
        }
        END { printf "B %d\n", mx }')
    local rtt bw
    rtt=$(awk '$1=="R"{print $2}' <<<"$out" | sort -n | awk '{a[NR]=$1} END{ if(NR>=5){i=int(NR*0.9+0.5); if(i<1)i=1; printf "%d", a[i]+0.5} else printf "-" }')
    bw=$(awk '$1=="B"{print $2}' <<<"$out"); echo "$rtt ${bw:-0}"
}

flush_passive() {
    local rtt bw pk
    read -r rtt bw < <(flow_sample)
    [[ $rtt != "-" && $rtt =~ ^[0-9]+$ ]] && (( rtt > 0 )) && add_sample R "$rtt"
    pk=$PEAK; (( bw > pk )) && pk=$bw
    (( pk >= 1 )) && add_sample P $(( pk * PASSIVE_HEADROOM_PCT / 100 ))
    PEAK=0
}

# ------------------------------------------------------------------ активный тест ----
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

yandex_urls() {  # свежие ссылки на 50-МБ зонды (привязаны к сессии, поэтому каждый раз запрашиваем заново)
    curl -fsS --max-time 10 -H "User-Agent: $TEST_UA" -H "Referer: https://yandex.ru/internet/" \
         -H "Accept: application/json" -- "$YANDEX_PROBES_API" 2>/dev/null \
      | grep -oE '"url":"https?://[^"]*/probes/50mb[^"]*"' | sed -e 's/^"url":"//' -e 's/"$//'
}

# один раунд: потоки качают суммарно total_bytes из ROUND_URLS -> "пик_Мбит длительность_мс принято_байт"
run_round() {  # $1 total_bytes; ROUND_URLS = шаблоны с @BYTES@ или статические файлы (тогда Range)
    local total=$1 nurl=${#ROUND_URLS[@]} streams per u url i p alive rx n=0 t0 maxf
    local pids=(); local -a T B rng
    streams=$TEST_PARALLEL; (( streams < nurl )) && streams=$nurl
    if [[ ${ROUND_URLS[0]} != *@BYTES@* ]]; then          # статика: поток не может скачать больше размера файла
        maxf=$(( STATIC_MAX_MB * 1000000 ))
        i=$(( (total + maxf - 1) / maxf )); (( i > streams )) && streams=$i
    fi
    per=$(( total / streams ))
    read -r rx _ < <(read_bytes); t0=$(now_ms); T[0]=$t0; B[0]=$rx
    for ((i = 0; i < streams; i++)); do
        u=${ROUND_URLS[i % nurl]}; rng=()
        if [[ $u == *@BYTES@* ]]; then url=${u//@BYTES@/$per}; else url=$u; rng=(-r "0-$(( per - 1 ))"); fi
        curl -fsSL ${rng[@]+"${rng[@]}"} ${CURL_EXTRA[@]+"${CURL_EXTRA[@]}"} -o /dev/null \
             --max-time "$TEST_MAX_SEC" -- "$url" >/dev/null 2>&1 &
        pids+=($!)
    done
    while :; do
        sleep 0.2
        read -r rx _ < <(read_bytes); n=$(( n + 1 )); T[n]=$(now_ms); B[n]=$rx
        alive=0; for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
        (( alive )) || break
        (( T[n] - t0 > TEST_MAX_SEC * 1000 + 3000 )) && break
    done
    kill "${pids[@]}" 2>/dev/null; wait "${pids[@]}" 2>/dev/null
    for ((i = 0; i <= n; i++)); do echo "${T[i]} ${B[i]}"; done | awk '
        {T[NR]=$1; B[NR]=$2}
        END{
            peak=0
            for(j=2;j<=NR;j++){
                for(i=j-1;i>=1;i--) if(T[j]-T[i]>=1000) break
                if(i<1) i=1
                dt=T[j]-T[i]; if(dt<400) continue
                r=(B[j]-B[i])*8/dt/1000; if(r>peak) peak=r
            }
            if(peak==0 && T[NR]>T[1]) peak=(B[NR]-B[1])*8/(T[NR]-T[1])/1000
            printf "%d %d %d\n", peak, T[NR]-T[1], B[NR]-B[1]
        }'
}

# лесенка: маленький тест; если он закончился слишком быстро (скорость высокая) — x3, и так до потолка
active_test() {  # печатает "best_mbit used_mb"
    command -v curl >/dev/null || { log "curl не найден"; echo "0 0"; return; }
    local s size best=0 used=0 left peak dur rx used_state
    local -a srcs Y
    used_state=$(state_get used_mb); used_state=${used_state:-0}
    if [[ $TEST_PROVIDER == yandex ]]; then
        mapfile -t Y < <(yandex_urls)
        if (( ${#Y[@]} > 0 )); then srcs+=("${Y[*]}"); else log "API Яндекса недоступен, перехожу к TEST_URLS"; fi
    fi
    for s in "${TEST_URLS[@]}"; do srcs+=("$s"); done
    for s in "${srcs[@]}"; do
        read -ra ROUND_URLS <<<"$s"
        CURL_EXTRA=(); [[ $s == *yandex.net* ]] && CURL_EXTRA=(-H "User-Agent: $TEST_UA" -H "Referer: https://yandex.ru/internet/")
        log "источник: ${ROUND_URLS[0]%%\?*} (+$(( ${#ROUND_URLS[@]} - 1 )))"
        size=64; best=0
        while :; do
            left=$(( TEST_BUDGET_GB * 1024 - used_state - used ))
            (( size > TEST_MAX_MB )) && size=$TEST_MAX_MB
            (( size > left )) && size=$left
            (( size < 16 )) && { log "бюджет тестов исчерпан"; break; }
            read -r peak dur rx < <(run_round $(( size * 1000000 )))
            used=$(( used + rx / 1000000 ))
            log "раунд ${size}МБ: пик=${peak}Мбит за ${dur}мс, принято $(( rx / 1000000 ))МБ"
            if (( dur < 2500 && rx < size * 250000 )); then
                log "источник не отдаёт данные"
                log "диагностика: $(curl -sS -o /dev/null -w 'http=%{http_code}' --max-time 8 -r 0-999999 ${CURL_EXTRA[@]+"${CURL_EXTRA[@]}"} -- "${ROUND_URLS[0]//@BYTES@/1000000}" 2>&1 | tail -1)"
                best=0; break
            fi
            (( peak > best )) && best=$peak
            (( dur >= 2500 || size >= TEST_MAX_MB )) && break
            size=$(( size * 3 ))
        done
        (( best > 0 )) && break
    done
    echo "$best $used"
}

budget_ok() {
    local m sm used
    m=$(date +%Y%m); sm=$(state_get month)
    if [[ $sm != "$m" ]]; then state_set month "$m"; state_set used_mb 0; fi
    used=$(state_get used_mb); used=${used:-0}
    (( used + 64 <= TEST_BUDGET_GB * 1024 ))
}

peer_fetch() {
    [[ -n $PEER_URL ]] || return 1
    local now last v
    now=$(date +%s); last=$(state_get peer_try); last=${last:-0}
    (( now - last < 6 * 3600 )) && return 1
    state_set peer_try "$now"
    v=$(curl -fsS --max-time 10 "$PEER_URL" 2>/dev/null | sed -n 's/^mbit=\([0-9]\+\)$/\1/p' | head -1)
    [[ $v =~ ^[0-9]+$ ]] && (( v > 0 )) || return 1
    add_sample A "$v"; state_set last_active "$now"; log "значение от лидера группы: ${v} Мбит"
}

should_calibrate() {
    local now last_try last_act p tier
    now=$(date +%s)
    last_try=$(state_get last_attempt); last_try=${last_try:-0}
    (( now - last_try < 6 * 3600 )) && return 1            # не чаще раза в 6 часов, даже при сбоях
    budget_ok || return 1
    last_act=$(state_get last_active); last_act=${last_act:-0}
    (( last_act == 0 )) && return 0                        # самый первый запуск
    (( now - last_act < RECHECK_DAYS * 86400 )) && return 1
    p=$(envelope P "$PASSIVE_WINDOW_DAYS"); tier=$(state_get tier); tier=${tier:-$DEFAULT_MBIT}
    (( p * 2 >= tier )) && return 1                        # нода занята — пассивные данные уже всё показывают
    return 0                                               # нода простаивает: проверяем, что ёмкость не изменилась
}

do_calibrate() {
    local res best used u
    state_set last_attempt "$(date +%s)"
    read -r best used < <(active_test)
    u=$(state_get used_mb); u=${u:-0}; state_set used_mb $(( u + used ))
    if (( best > 0 )); then
        add_sample A "$best"; state_set last_active "$(date +%s)"
        log "активный замер: ${best} Мбит (потрачено ${used} МБ, за месяц $(( u + used )) МБ)"
        return 0
    fi
    log "активный замер не удался (потрачено ${used} МБ)"; return 1
}

# ------------------------------------------------------------------- логика решения ---
to_tier() {
    local x=$1 t
    for t in "${TIERS[@]}"; do (( t >= x )) && { echo "$t"; return; }; done
    echo "${TIERS[${#TIERS[@]}-1]}"
}

link_cap() {
    local c=$PORT_CAP_MBIT s
    if (( NIC_SPEED_CAP )); then
        s=$(cat "/sys/class/net/$IFACE/speed" 2>/dev/null)
        [[ $s =~ ^[0-9]+$ ]] && (( s > 0 )) && { (( c == 0 || s < c )) && c=$s; }
    fi
    echo "$c"
}

decide() {  # $1 = 1 сохранить состояние; задаёт TIER, RTT, EST_INFO
    local commit=${1:-0} now cap p a est cand cur ds r
    now=$(date +%s)
    cap=$(link_cap); p=$(envelope P "$PASSIVE_WINDOW_DAYS"); a=$(max_recent A "$LOG_KEEP_DAYS")
    est=$(( p > a ? p : a )); EST_INFO="пассивно=${p} активно=${a} потолок=${cap} Мбит"
    (( est == 0 )) && est=$DEFAULT_MBIT
    (( cap > 0 && est > cap )) && est=$cap
    cand=$(to_tier "$est"); cur=$(state_get tier); TIER=$cand
    if [[ -n $cur ]]; then
        ds=$(state_get down_since); ds=${ds:-0}
        if (( cand > cur )); then
            (( commit )) && state_set down_since 0
        elif (( cand < cur )); then
            TIER=$cur
            if (( ds == 0 )); then
                (( commit )) && state_set down_since "$now"
            elif (( now - ds >= DOWN_CONFIRM_SEC )); then
                TIER=$cand; (( commit )) && state_set down_since 0
            fi
        else
            (( commit )) && state_set down_since 0
        fi
    fi
    (( commit )) && state_set tier "$TIER"
    r=$(rtt_design); (( r == 0 )) && r=$DEFAULT_RTT_MS
    (( r < RTT_MIN_MS )) && r=$RTT_MIN_MS; (( r > RTT_MAX_MS )) && r=$RTT_MAX_MS
    RTT=$(( (r + 24) / 25 * 25 ))
}

# ------------------------------------------------------------------ генерация sysctl --
have_bbr() {
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && return 0
    [[ $DRY_RUN == 1 ]] || modprobe tcp_bbr 2>/dev/null
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

clamp() { local v=$1 lo=$2 hi=$3; (( v < lo )) && v=$lo; (( v > hi )) && v=$hi; echo "$v"; }

render() {  # $1 тир (Мбит), $2 RTT (мс)
    local tier=$1 rtt=$2 ram_kb pgsz pages ram_mb buf hi bl ct minfree filemax
    ram_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    pgsz=$(getconf PAGESIZE 2>/dev/null || echo 4096)
    ram_mb=$(( ram_kb / 1024 )); pages=$(( ram_kb * 1024 / pgsz ))

    # буфер = 2 x BDP (BBR держит до ~2 BDP в полёте); BDP[байт] = Мбит * 125 * RTT[мс]
    buf=$(( tier * 125 * rtt * 2 ))
    hi=$(( ram_kb * 64 )); (( hi > 268435456 )) && hi=268435456     # не больше 1/16 RAM на сокет и 256 МиБ
    buf=$(clamp "$buf" 8388608 "$hi")                                # минимум 8 МиБ: нужно QUIC/Hysteria/TUIC
    buf=$(( buf / 1048576 * 1048576 )); (( buf < 8388608 )) && buf=8388608

    bl=$(clamp $(( tier * 16 )) 4096 65536)
    ct=$(clamp $(( ram_mb * 64 )) 32768 2097152); ct=$(( (ct + 4095) / 4096 * 4096 ))
    minfree=$(clamp $(( ram_kb / 100 )) 8192 131072)
    filemax=$(clamp $(( ram_mb * 256 )) 65536 4194304)

    echo "# netautotune: тир=${tier} Мбит, RTT=${rtt} мс, RAM=${ram_mb} МБ  ($(date '+%F %T'))"
    echo "# Файл генерируется автоматически, правки вносите в $CONF_FILE"
    echo
    echo "# --- Очереди и контроль перегрузки ---"
    echo "net.core.default_qdisc = fq"
    if have_bbr; then echo "net.ipv4.tcp_congestion_control = bbr"; else echo "# bbr недоступен в этом ядре"; fi
    echo "net.ipv4.tcp_slow_start_after_idle = 0"
    echo
    echo "# --- Буферы (от тира и RTT; это потолки, память выделяется по мере надобности) ---"
    echo "net.core.rmem_max = $buf"
    echo "net.core.wmem_max = $buf"
    echo "net.ipv4.tcp_rmem = 4096 131072 $buf"
    echo "net.ipv4.tcp_wmem = 4096 131072 $buf"
    echo "net.ipv4.udp_rmem_min = 16384"
    echo "net.ipv4.udp_wmem_min = 16384"
    echo "net.ipv4.tcp_mem = $(( pages / 32 )) $(( pages / 16 )) $(( pages / 8 ))"
    echo "net.ipv4.udp_mem = $(( pages / 32 )) $(( pages / 16 )) $(( pages / 8 ))"
    echo
    echo "# --- conntrack (от RAM). buckets = max/4 задаётся через hashsize модуля, не sysctl ---"
    echo "-net.netfilter.nf_conntrack_max = $ct"
    echo "-net.netfilter.nf_conntrack_tcp_timeout_established = 3600"
    echo "-net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30"
    echo "-net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30"
    echo "-net.netfilter.nf_conntrack_udp_timeout = 10"
    echo "-net.netfilter.nf_conntrack_udp_timeout_stream = 120"
    echo
    echo "# --- Очереди и backlog (от тира) ---"
    echo "net.core.netdev_max_backlog = $bl"
    echo "net.core.somaxconn = $(( bl > 65535 ? 65535 : bl ))"
    echo "net.ipv4.tcp_max_syn_backlog = $bl"
    echo
    echo "# --- Таймауты, reuse, fastopen, keepalive ---"
    echo "net.ipv4.ip_local_port_range = 10240 65535"
    echo "net.ipv4.tcp_fin_timeout = 15"
    echo "net.ipv4.tcp_tw_reuse = 1"
    echo "net.ipv4.tcp_max_tw_buckets = $ct"
    echo "net.ipv4.tcp_fastopen = 3"
    echo "net.ipv4.tcp_mtu_probing = 1"
    echo "net.ipv4.tcp_keepalive_time = 600"
    echo "net.ipv4.tcp_keepalive_intvl = 15"
    echo "net.ipv4.tcp_keepalive_probes = 5"
    echo "net.ipv4.tcp_synack_retries = 3"
    echo "net.ipv4.tcp_orphan_retries = 3"
    echo "net.ipv4.tcp_no_metrics_save = 1"
    echo "net.ipv4.tcp_notsent_lowat = 131072"
    echo "-net.core.gro_normal_batch = 16"
    echo
    echo "# --- Безопасность ---"
    echo "net.ipv4.tcp_rfc1337 = 1"
    echo "net.ipv4.conf.all.accept_redirects = 0"
    echo "net.ipv4.conf.default.accept_redirects = 0"
    echo "net.ipv4.conf.all.secure_redirects = 0"
    echo "net.ipv4.conf.default.secure_redirects = 0"
    echo "net.ipv4.conf.all.send_redirects = 0"
    echo "net.ipv4.conf.default.send_redirects = 0"
    echo "net.ipv4.conf.all.accept_source_route = 0"
    echo "net.ipv4.conf.default.accept_source_route = 0"
    (( ICMP_IGNORE )) && echo "net.ipv4.icmp_echo_ignore_all = 1"
    if (( DISABLE_IPV6 )); then
        echo
        echo "# --- IPv6 выключен ---"
        echo "net.ipv6.conf.all.disable_ipv6 = 1"
        echo "net.ipv6.conf.default.disable_ipv6 = 1"
    fi
    echo
    echo "# --- Память и файлы (от RAM) ---"
    echo "vm.swappiness = 10"
    echo "vm.min_free_kbytes = $minfree"
    echo "vm.vfs_cache_pressure = 50"
    echo "fs.file-max = $filemax"
    CT_HASH=$(( ct / 4 ))
}

apply_conntrack_hash() {
    local h=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 * 64 ))
    h=$(clamp "$h" 32768 2097152); h=$(( (h + 4095) / 4096 * 4096 / 4 ))
    [[ -d /sys/module/nf_conntrack ]] || return 0
    [[ -w /sys/module/nf_conntrack/parameters/hashsize ]] && echo "$h" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null
    echo "options nf_conntrack hashsize=$h" > "$CT_MODPROBE"
}

fix_qdisc() {
    command -v tc >/dev/null || return 0
    local q
    q=$(tc qdisc show dev "$IFACE" root 2>/dev/null | awk '{print $2; exit}')
    case $q in
        fq|"") ;;
        fq_codel|pfifo_fast) tc qdisc replace dev "$IFACE" root fq 2>/dev/null && log "qdisc на $IFACE: $q -> fq" ;;
        *) log "qdisc на $IFACE = $q: fq применится при следующем подъёме интерфейса (default_qdisc)" ;;
    esac
}

apply_conf() {  # $1 тир, $2 RTT, $3 force(1/0)
    local new body_new body_old
    new=$(render "$1" "$2") || return 1
    body_new=$(grep -v '^#' <<<"$new")
    body_old=$([[ -f $OUT_FILE ]] && grep -v '^#' "$OUT_FILE")
    if [[ ${3:-0} != 1 && $body_new == "$body_old" ]]; then return 0; fi
    if (( DRY_RUN )); then echo "$new"; return 0; fi
    printf '%s\n' "$new" > "$OUT_FILE.tmp" && mv "$OUT_FILE.tmp" "$OUT_FILE"
    sysctl -e -q -p "$OUT_FILE" >/dev/null
    apply_conntrack_hash; fix_qdisc
    log "применено: тир=$1 Мбит, RTT=$2 мс"
}

# -------------------------------------------------------------------------- команды --
cycle() {
    flush_passive
    prune_log
    peer_fetch
    if should_calibrate; then
        do_calibrate; PRX=""; PEAK=0
    fi
    decide 1; apply_conf "$TIER" "$RTT" 0
}

cmd_daemon() {
    need_iface; init_state
    trap 'log "остановка"; exit 0' TERM INT
    PEAK=0; PRX=""; PTX=""
    log "старт: интерфейс=$IFACE, пересчёт каждые ${EVAL_SEC}с"
    decide 1; apply_conf "$TIER" "$RTT" 1          # на старте всегда восстанавливаем конфиг
    local next=$(( $(date +%s) + 60 ))             # первый цикл через минуту после старта
    while :; do
        sleep "$SAMPLE_SEC"
        sample_tick
        if (( $(date +%s) >= next )); then
            cycle; next=$(( $(date +%s) + EVAL_SEC ))
        fi
    done
}

cmd_eval() { need_iface; init_state; decide 1; apply_conf "$TIER" "$RTT" 1; echo "тир=${TIER} Мбит, RTT=${RTT} мс  ($EST_INFO)"; }

cmd_calibrate() {
    need_iface; init_state
    state_set last_attempt 0
    budget_ok || { echo "Месячный бюджет тестов исчерпан (TEST_BUDGET_GB=$TEST_BUDGET_GB)"; exit 1; }
    do_calibrate; cmd_eval
}

cmd_status() {
    need_iface; init_state; decide 0
    local cur used la
    cur=$(state_get tier); used=$(state_get used_mb); la=$(state_get last_active)
    echo "интерфейс:         $IFACE (NIC speed: $(cat /sys/class/net/$IFACE/speed 2>/dev/null || echo n/a))"
    echo "применённый тир:   ${cur:-—} Мбит"
    echo "расчётный тир:     $TIER Мбит   ($EST_INFO)"
    echo "расчётный RTT:     $RTT мс   (замеров RTT за 7д: $(awk -v s=$(( $(date +%s) - 604800 )) '$2=="R"&&$1>=s' "$LOG" | wc -l))"
    echo "последний тест:    $([[ -n $la && $la != 0 ]] && date -d @"$la" '+%F %T' || echo никогда)"
    echo "трафик на тесты:   ${used:-0} МБ в этом месяце из $(( TEST_BUDGET_GB * 1024 )) МБ"
    [[ $(state_get down_since) -gt 0 ]] 2>/dev/null && echo "снижение тира:     ожидает подтверждения с $(date -d @"$(state_get down_since)" '+%F %T')"
    echo "qdisc:             $(tc qdisc show dev "$IFACE" root 2>/dev/null | head -1)"
    echo "cc:                $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
}

cmd_export() { need_iface; init_state; decide 0; echo "mbit=$TIER"; echo "rtt=$RTT"; }

cmd_render() {
    init_state
    if [[ $# -ge 2 ]]; then render "$1" "$2"; else need_iface; decide 0; render "$TIER" "$RTT"; fi
}

cmd_install() {
    [[ $EUID -eq 0 ]] || { echo "Нужен root" >&2; exit 1; }
    install -m 755 "$(readlink -f "$0")" "$SELF_BIN"
    if [[ ! -f $CONF_FILE ]]; then
        cat > "$CONF_FILE" <<EOF
# Конфиг netautotune. Раскомментируйте и измените нужное.
#IFACE=""
#PORT_CAP_MBIT=0          # потолок по тарифу (если знаете, укажите — например 1000)
#TEST_BUDGET_GB=10        # месячный бюджет трафика на speedtest
#TEST_MAX_MB=1000         # потолок одного теста
#TEST_PROVIDER="yandex"   # yandex | custom (только TEST_URLS)
#RECHECK_DAYS=14
#PEER_URL=""              # URL, где лидер группы публикует вывод 'netautotune export'
#DISABLE_IPV6=1
#ICMP_IGNORE=0
EOF
    fi
    echo "tcp_bbr" > "$BBR_MODLOAD"
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=netautotune: adaptive network sysctl tuner
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$SELF_BIN daemon
Restart=on-failure
RestartSec=30
Nice=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now netautotune.service
    echo "Установлено. Проверка: netautotune status ; логи: journalctl -u netautotune -f"
}

cmd_uninstall() {
    [[ $EUID -eq 0 ]] || { echo "Нужен root" >&2; exit 1; }
    systemctl disable --now netautotune.service 2>/dev/null
    rm -f "$UNIT_FILE" "$SELF_BIN" "$OUT_FILE" "$CT_MODPROBE" "$BBR_MODLOAD"
    systemctl daemon-reload
    echo "Удалено (состояние в $STATE_DIR и $CONF_FILE оставлены)."
}

usage() {
    cat <<EOF
netautotune $VERSION
  install            установить как systemd-сервис
  uninstall          удалить
  daemon             основной цикл (его запускает systemd)
  eval               пересчитать и применить по накопленным данным (без теста)
  calibrate          принудительно сделать активный замер (в рамках бюджета) и применить
  status             показать состояние
  render [тир rtt]   напечатать sysctl-конфиг (например: render 6000 50)
  export             вывести mbit=/rtt= для остальных нод группы (PEER_URL)
Переменная DRY_RUN=1 — ничего не писать в систему.
EOF
}

cmd=${1:-help}; shift || true
case $cmd in
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    daemon)    cmd_daemon ;;
    eval)      cmd_eval ;;
    calibrate) cmd_calibrate ;;
    status)    cmd_status ;;
    render)    cmd_render "$@" ;;
    export)    cmd_export ;;
    *)         usage ;;
esac