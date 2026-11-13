#!/bin/sh
# 跨会话消息板：文件即消息，无守护进程、无网络、无推送。
# 群聊（post/new/history/digest/join）+ 点对点（send/list/read）。
# 用法见同目录 README.md；数据落 misc/msgbus/（已被 .gitignore 排除）。
set -u

# 消息目录解析：显式 MSGBUS_DIR > 工作区布局（脚本 ../../ 有 INDEX.md）> ~/.msgbus
W=$(CDPATH= cd -- "$(dirname -- "$0")/../.." 2>/dev/null && pwd || true)
if [ -n "${MSGBUS_DIR:-}" ]; then
    ROOT=$MSGBUS_DIR
elif [ -n "$W" ] && [ -f "$W/INDEX.md" ]; then
    ROOT=$W/misc/msgbus
else
    ROOT=${HOME:-.}/.msgbus
fi
SPOOL=$ROOT/spool
SEEK=$ROOT/seen
ARCH=$ROOT/archive
MEM=$ROOT/members
MSG_MAX=${MSG_MAX:-30}       # new/join 一次最多显示多少条
MSG_CHARS=${MSG_CHARS:-4000} # 单条最多显示多少字符

usage() {
    cat <<'EOF'
群聊（几个会话共享一份日志）：
  msg.sh post FROM < 正文        # 首行写 refs: <commit/文件>，正文≤5 行
  msg.sh new FROM                # 只看自己没看过的（不含自己发的），看完记已读
  msg.sh history [--all]         # 群历史；--all 连已压缩归档的也列
  msg.sh digest FROM 标题 < 摘要  # 把现有群消息压成一条摘要并归档原文
  msg.sh join FROM               # 新会话/新项目对齐包：摘要 + 未读 + 最近提交 + 项目表
  msg.sh leave FROM [说明]       # 退出/归档：登记 left 并在群里留一句
  msg.sh members                 # 谁还在群里（active / left + 最后活动时间）

点对点：
  msg.sh send FROM TO 标题 < 正文
  msg.sh list TO / read TO [ID] / all TO

约定：会话名自取、中文可；数据在 misc/msgbus/，不进 git。
没有推送：别人不会被打断，主动跑 new 才看得到。
EOF
}

clean() {
    # 只清有路径危险的字符：路径分隔符、控制字符、前导点；中文原样保留
    printf '%s' "$1" | tr -d '\000-\037' | sed 's#[/\\]#_#g; s/^\.\+/_/' | cut -c1-60
}

now_id() {
    ns=$(date +%N 2>/dev/null || true)
    [ -n "$ns" ] || ns=000000000
    echo "$(date +%Y%m%d-%H%M%S)-$ns-$1-$$"
}

reg_member() { # NAME STATUS [NOTE]
    mkdir -p "$MEM" || return 1
    printf 'status: %s\nupdated: %s\nnote: %s\n' \
        "$2" "$(date +%Y-%m-%dT%H:%M:%S%z)" "${3:--}" > "$MEM/$(clean "$1")"
}

# digest 互斥：并发压缩会让同一批消息产生两条摘要（实测过），用目录锁串行化
acquire_digest_lock() {
    lock=$ROOT/.digest.lock
    i=0
    while [ "$i" -lt 25 ]; do
        if mkdir "$lock" 2>/dev/null; then printf '%s\n' "$$" > "$lock/pid"; return 0; fi
        if [ -f "$lock/pid" ]; then
            pid=$(cat "$lock/pid" 2>/dev/null || true)
            if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$lock"; continue; fi
        fi
        sleep 0.2 2>/dev/null || sleep 1
        i=$((i + 1))
    done
    return 1
}

read_body() {
    body=$(cat)
    body=$(printf '%s\n' "$body" | sed '/./,$!d')
    [ -n "$body" ] || { echo "正文为空，未写入" >&2; exit 2; }
    printf '%s\n' "$body"
}

write_msg() {
    from=$1; to=$2; subj=$3; body=$4; scope=$5; refs=${6:-}; covers=${7:-}; upto=${8:-}
    mkdir -p "$SPOOL" "$SEEK" || exit 1
    [ -n "$to" ] && mkdir -p "$ARCH/$to"
    id=$(now_id "$from"); f="$SPOOL/$id.msg"
    {
        printf 'from: %s\n' "$from"
        [ -n "$to" ] && printf 'to: %s\n' "$to"
        printf 'scope: %s\n' "$scope"
        printf 'refs: %s\n' "${refs:--}"
        [ -n "$covers" ] && printf 'covers: %s\n' "$covers"
        [ -n "$upto" ] && printf 'upto: %s\n' "$upto"
        printf 'time: %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)"
        [ -n "$subj" ] && printf 'subject: %s\n' "$subj"
        printf '\n%s\n' "$body"
    } > "$f.tmp" && mv "$f.tmp" "$f" || exit 1
    echo "$f"
}

cmd_post() {
    [ $# -ge 1 ] || { usage >&2; exit 2; }
    from=$(clean "$1"); body=$(read_body)
    refs=""; first=$(printf '%s\n' "$body" | head -1)
    case "$first" in
        refs:*)
            refs=$(printf '%s' "$first" | sed 's/^refs:[[:space:]]*//'); refs=${refs:--}
            body=$(printf '%s\n' "$body" | sed '1d') ;;
        *)
            refs="-"
            echo "提示：群消息首行应写 'refs: <commit 或 文件路径>'，已按 refs: - 记录" >&2 ;;
    esac
    [ -n "$body" ] || { echo "refs 之外没有正文，未写入" >&2; exit 2; }
    reg_member "$from" active "-"
    write_msg "$from" "" "" "$body" group "$refs"
}

cmd_send() {
    [ $# -ge 3 ] || { usage >&2; exit 2; }
    from=$(clean "$1"); to=$(clean "$2"); subj=$3; body=$(read_body)
    write_msg "$from" "$to" "$subj" "$body" direct
}

showable() {
    f=$1; me=$2
    grep -Eqx 'scope: (group|digest)' "$f" 2>/dev/null || return 1
    [ "$(sed -n 's/^from: //p' "$f" | head -1)" = "$me" ] && return 1
    return 0
}

print_msg() {
    f=$1
    printf '## %s  %s' \
        "$(sed -n 's/^time: //p' "$f" | head -1 | cut -c1-19)" \
        "$(sed -n 's/^from: //p' "$f" | head -1)"
    if grep -qx 'scope: digest' "$f" 2>/dev/null; then
        printf '  [摘要 %s 条]' "$(sed -n 's/^covers: //p' "$f" | head -1)"
    fi
    subj=$(sed -n 's/^subject: //p' "$f" | head -1)
    [ -n "$subj" ] && printf '  %s' "$subj"
    echo
    refs=$(sed -n 's/^refs: //p' "$f" | head -1)
    [ -n "$refs" ] && [ "$refs" != "-" ] && printf '   refs: %s\n' "$refs"
    sed -n '/^$/,$p' "$f" | sed '1d' | cut -c1-"$MSG_CHARS"
    echo
}

cmd_new() {
    [ $# -ge 1 ] || { usage >&2; exit 2; }
    me=$(clean "$1"); mkdir -p "$SEEK"; sf="$SEEK/$me"; touch "$sf"
    n=0; unseen=0; more=0
    for f in "$SPOOL"/*.msg; do
        [ -e "$f" ] || continue
        id=$(basename "$f" .msg)
        showable "$f" "$me" || continue
        grep -qxF "$id" "$sf" && continue
        unseen=$((unseen + 1))
        [ "$n" -ge "$MSG_MAX" ] && { more=1; continue; }
        print_msg "$f"; printf '%s\n' "$id" >> "$sf"; n=$((n + 1))
    done
    [ "$n" = 0 ] && echo "（没有新消息）"
    [ "$more" = 1 ] && echo "… 还有 $((unseen - n)) 条未显示（MSG_MAX=$MSG_MAX），再跑一次 new"
    return 0
}

cmd_history() {
    all=0; [ "${1:-}" = "--all" ] && all=1
    total=0
    if [ "$all" = 1 ] && [ -d "$ARCH/group" ]; then
        for f in "$ARCH/group"/*.msg; do
            [ -e "$f" ] || continue; total=$((total + 1)); print_msg "$f"
        done
    fi
    for f in "$SPOOL"/*.msg; do
        [ -e "$f" ] || continue
        grep -Eqx 'scope: (group|digest)' "$f" 2>/dev/null || continue
        total=$((total + 1)); print_msg "$f"
    done
    [ "$total" = 0 ] && echo "（群里空的）"
    return 0
}

cmd_digest() {
    [ $# -ge 2 ] || { usage >&2; exit 2; }
    from=$(clean "$1"); subj=$2; body=$(read_body)
    acquire_digest_lock || { echo "另一个会话正在 digest，稍后再试（锁：$ROOT/.digest.lock）" >&2; exit 1; }
    trap 'rm -rf "$ROOT/.digest.lock"' EXIT INT TERM
    ids=""; cnt=0; upto=""
    for f in "$SPOOL"/*.msg; do
        [ -e "$f" ] || continue
        grep -qx 'scope: group' "$f" 2>/dev/null || continue
        ids="$ids $(basename "$f" .msg)"; cnt=$((cnt + 1)); upto=$(basename "$f" .msg)
    done
    [ "$cnt" -gt 0 ] || { echo "群里没有需要压缩的群消息" >&2; exit 1; }
    mkdir -p "$ARCH/group"
    f=$(write_msg "$from" "" "$subj" "$body" digest "-" "$cnt" "$upto")
    for id in $ids; do mv "$SPOOL/$id.msg" "$ARCH/group/$id.msg" 2>/dev/null || true; done
    # 不写别人的游标：摘要对没读过原文的会话（含新会话）仍然算新消息
    rm -rf "$ROOT/.digest.lock"
    trap - EXIT INT TERM
    echo "已压缩 $cnt 条 → $f（原文移入 $ARCH/group/）"
}

cmd_join() {
    [ $# -ge 1 ] || { usage >&2; exit 2; }
    me=$(clean "$1"); reg_member "$me" active "-"
    echo "== 群最新摘要"
    d=""
    for f in $(ls -1t "$SPOOL"/*.msg 2>/dev/null); do
        grep -qx 'scope: digest' "$f" && { d=$f; break; }
    done
    if [ -n "$d" ]; then
        mkdir -p "$SEEK"; sf="$SEEK/$me"; touch "$sf"
        print_msg "$d"
        printf '%s\n' "$(basename "$d" .msg)" >> "$sf"   # 已随 join 展示，new 不再重复
    else
        echo "（还没有摘要，直接看未读）"
    fi
    echo "== 我的未读"
    cmd_new "$me"
    echo "== 工作区最近提交"
    git -C "$W" log --oneline -8 2>/dev/null || echo "（$W 不是 git 仓库）"
    if [ -f "$W/INDEX.md" ]; then
        echo "== 项目表（INDEX 第 4 节）"
        sed -n '/^## 4\. 项目/,/^## 5\./p' "$W/INDEX.md" | sed '$d'
    fi
    return 0
}

cmd_leave() {
    [ $# -ge 1 ] || { usage >&2; exit 2; }
    from=$(clean "$1"); shift || true; note=${1:-}
    reg_member "$from" left "${note:--}"
    write_msg "$from" "" "离开" "退出群聊/归档：${note:-无说明}" group "-" >/dev/null
    echo "$from 已标记 left，群里留了一条公告；看成员表用 msg.sh members"
}

cmd_members() {
    if [ -d "$MEM" ] && [ -n "$(ls -A "$MEM" 2>/dev/null)" ]; then
        for f in "$MEM"/*; do
            [ -f "$f" ] || continue
            printf '%-18s %-6s %s' "$(basename "$f")" \
                "$(sed -n 's/^status: //p' "$f" | head -1)" \
                "$(sed -n 's/^updated: //p' "$f" | head -1 | cut -c1-19)"
            n=$(sed -n 's/^note: //p' "$f" | head -1)
            [ -n "$n" ] && [ "$n" != "-" ] && printf '  %s' "$n"
            echo
        done
    else
        echo "（还没有成员：谁 post 或 join 过才会自动登记）"
    fi
    return 0
}

cmd_list() {
    [ $# -ge 1 ] || { usage >&2; exit 2; }
    to=$(clean "$1"); found=0
    for f in "$SPOOL"/*.msg; do
        [ -e "$f" ] || continue
        grep -qx "to: $to" "$f" 2>/dev/null || continue
        found=1
        printf '%s  %-14s %s\n' "$(basename "$f" .msg)" \
            "$(sed -n 's/^from: //p' "$f" | head -1)" \
            "$(sed -n 's/^subject: //p' "$f" | head -1)"
    done
    [ "$found" = 1 ] || echo "（$to 没有未读消息）"
}

cmd_read() {
    [ $# -ge 1 ] || { usage >&2; exit 2; }
    to=$(clean "$1"); want=${2:-}
    if [ -n "$want" ]; then
        f="$SPOOL/$want.msg"
        [ -e "$f" ] || { echo "没有这条未读消息：$want" >&2; exit 1; }
        grep -qx "to: $to" "$f" || { echo "$want 不是发给 $to 的" >&2; exit 1; }
    else
        f=""
        for c in $(ls -1t "$SPOOL"/*.msg 2>/dev/null); do
            grep -qx "to: $to" "$c" && { f="$c"; break; }
        done
        [ -n "$f" ] || { echo "（$to 没有未读消息）"; exit 0; }
    fi
    cat "$f"; mkdir -p "$ARCH/$to"
    mv "$f" "$ARCH/$to/$(basename "$f")"
    echo "--- 已归档：$ARCH/$to/$(basename "$f")"
}

cmd_all() {
    [ $# -ge 1 ] || { usage >&2; exit 2; }
    to=$(clean "$1"); found=0
    for d in "$SPOOL" "$ARCH/$to"; do
        [ -d "$d" ] || continue
        st=未读; [ "$d" = "$ARCH/$to" ] && st=已归档
        for f in "$d"/*.msg; do
            [ -e "$f" ] || continue
            grep -qx "to: $to" "$f" 2>/dev/null || continue
            found=1
            printf '%-6s %s  %-14s %s\n' "$st" "$(basename "$f" .msg)" \
                "$(sed -n 's/^from: //p' "$f" | head -1)" \
                "$(sed -n 's/^subject: //p' "$f" | head -1)"
        done
    done
    [ "$found" = 1 ] || echo "（$to 没有任何消息）"
}

cmd=${1:-help}
[ $# -gt 0 ] && shift
case "$cmd" in
    post) cmd_post "$@" ;;
    new) cmd_new "$@" ;;
    history) cmd_history "$@" ;;
    digest) cmd_digest "$@" ;;
    join) cmd_join "$@" ;;
    leave) cmd_leave "$@" ;;
    members) cmd_members ;;
    send) cmd_send "$@" ;;
    list) cmd_list "$@" ;;
    read) cmd_read "$@" ;;
    all) cmd_all "$@" ;;
    help|-h|--help) usage ;;
    *) echo "未知命令：$cmd" >&2; usage >&2; exit 2 ;;
esac
