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
# 统一时间基准：两侧环境默认时区不同（chroot=UTC、Android=本地），
# 不统一会让同一瞬间写出两个日期，按文件名排序就错序了
TZ=UTC0; export TZ
SPOOL=$ROOT/spool
SEEK=$ROOT/seen
ARCH=$ROOT/archive
MEM=$ROOT/members
MSG_MAX=${MSG_MAX:-30}       # new/join 一次最多显示多少条
MSG_CHARS=${MSG_CHARS:-4000} # 单条最多显示多少字符

usage() {
    cat <<'EOF'
群聊（几个会话共享一份日志）：
  msg.sh post FROM [--attach 路径[,路径]] < 正文   # 可附带图片/文件路径
  msg.sh new FROM [--all]        # 只看自己没看过的；首次默认从当前最新开始（--all 追历史）
  msg.sh history [--all]         # 群历史；--all 连已压缩归档的也列
  msg.sh digest FROM 标题 < 摘要  # 把现有群消息压成一条摘要并归档原文
  msg.sh intro FROM 职责 [不碰什么]  # 自我介绍（结构化：我是谁/管什么/不碰什么）
  msg.sh agree FROM 消息id [一句话]  # 对某条消息表态
  msg.sh decide FROM 标题 < 结论     # 把讨论收口，记一条结论
  msg.sh join FROM               # 新会话/新项目对齐包：摘要 + 未读 + 最近提交 + 项目表
  msg.sh leave FROM [说明]       # 退出/归档：登记 left 并在群里留一句
  msg.sh members                 # 谁还在群里（active / left + 最后活动时间）
  msg.sh forget 名字             # 删掉这条成员记录（它发过的消息不动）
  msg.sh brief 名字 [目录]        # 生成一段开场白，粘给那个会话

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
    from=$1; to=$2; subj=$3; body=$4; scope=$5; refs=${6:-}; covers=${7:-}; upto=${8:-}; extra=${9:-}
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
        [ -n "$extra" ] && printf '%s\n' "$extra"
        printf 'time: %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)"
        [ -n "$subj" ] && printf 'subject: %s\n' "$subj"
        printf '\n%s\n' "$body"
    } > "$f.tmp" && mv "$f.tmp" "$f" || exit 1
    echo "$f"
}

cmd_post() {
    [ $# -ge 1 ] || { usage >&2; exit 2; }
    from=$(clean "$1"); shift
    attach=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --attach) attach=$(printf '%s' "${2:-}" | tr -d ' '); shift 2 ;;
            *) break ;;
        esac
    done
    body=$(read_body)
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
    case "$body" in
        from:*|scope:*|time:*|subject:*|covers:*)
            echo "警告：正文第一行看起来是消息头部（${body%%\n*}）。" >&2
            echo "      post 会自动加头部，把整条消息贴进来会产生「头部套头部」。" >&2 ;;
    esac
    reg_member "$from" active "-"
    if [ -n "$attach" ]; then
        write_msg "$from" "" "" "$body" group "$refs" "" "" "attachments: $attach"
    else
        write_msg "$from" "" "" "$body" group "$refs"
    fi
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
    # 一条消息只 fork 一次 awk（原来要 6 次 sed/cut），大量消息时差别很明显
    awk -v max="$MSG_CHARS" '
        FNR==1 { from=""; t=""; refs=""; subj=""; covers=""; scope="group"; att=""; body=0; buf="" }
        !body {
            if ($0 == "") { body=1; next }
            if ($0 ~ /^from: /) from=substr($0,7)
            else if ($0 ~ /^time: /) t=substr($0,7)
            else if ($0 ~ /^refs: /) refs=substr($0,7)
            else if ($0 ~ /^subject: /) subj=substr($0,10)
            else if ($0 ~ /^covers: /) covers=substr($0,9)
            else if ($0 ~ /^scope: /) scope=substr($0,8)
            else if ($0 ~ /^attachments: /) att=substr($0,14)
            next
        }
        { buf = buf $0 "\n" }
        END {
            head = "## " substr(t,1,19) "  " from
            if (scope == "digest") head = head "  [摘要 " covers " 条]"
            if (subj != "") head = head "  " subj
            print head
            if (refs != "" && refs != "-") print "   refs: " refs
            if (att != "") print "   📎 " att
            if (buf != "") printf "%s", substr(buf,1,max)
            print ""
        }' "$1"
}

cmd_new() {
    [ $# -ge 1 ] || { usage >&2; exit 2; }
    me=$(clean "$1"); shift || true
    show_all=0
    [ "${1:-}" = "--all" ] && show_all=1
    mkdir -p "$SEEK"; sf="$SEEK/$me"; touch "$sf"
    last=$(tail -1 "$sf" 2>/dev/null || true)

    # 第一次用这个名字：默认不追历史，直接把游标设到当前最新，避免新会话对入群前的
    # 旧消息逐条反应（要看历史用 new --all 或 join）
    if [ -z "$last" ] && [ "$show_all" = 0 ]; then
        newest=$(cd "$SPOOL" 2>/dev/null && ls -1 *.msg 2>/dev/null | tail -1 | sed 's/\.msg$//')
        if [ -n "$newest" ]; then
            printf '%s\n' "$newest" >> "$sf"
            echo "（首次使用「$me」：已把游标设到当前最新，之后只看新消息）"
            echo "（要看入群前的历史：msg.sh new $me --all，或 msg.sh join $me）"
            return 0
        fi
    fi

    # 一次 awk 扫完：挑出「文件名 > 游标」且 scope=group、不是自己发的
    cand=$(cd "$SPOOL" 2>/dev/null && awk -v c="$last" -v me="$me" '
        FNR==1 { f=FILENAME; sub(/\.msg$/, "", f); from=""; scope="group" }
        FNR<=8 {
            if ($0 ~ /^from: /) { from=substr($0,7) }
            else if ($0 ~ /^scope: /) { scope=substr($0,8) }
            else if ($0 == "") {
                if (f > c && scope == "group" && from != me) print f
                nextfile
            }
        }' *.msg 2>/dev/null)

    # 一次 grep -vxF 去掉已读，避免每个文件 fork 一次
    if [ -n "$cand" ] && [ -s "$sf" ]; then
        cand=$(printf '%s\n' $cand | grep -vxF -f "$sf" || true)
    fi

    n=0; shown=""; rest=0
    for id in $cand; do
        if [ "$n" -lt "$MSG_MAX" ]; then
            print_msg "$SPOOL/$id.msg"
            shown="$shown $id"; n=$((n + 1))
        else
            rest=$((rest + 1))     # 超出上限的不标记已读，下次还能看到
        fi
    done
    [ -n "$shown" ] && printf '%s\n' $shown >> "$sf"

    [ "$n" = 0 ] && echo "（没有新消息）"
    [ "$rest" -gt 0 ] && echo "… 还有 $rest 条未显示（MSG_MAX=$MSG_MAX），再跑一次 new"
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

# 自我介绍：别人 new 时一眼知道你是谁、管什么、不碰什么
cmd_intro() {
    [ $# -ge 2 ] || { usage >&2; exit 2; }
    from=$(clean "$1"); duty=$2; bound=${3:--}
    body=$(printf '我是 %s。\n职责：%s\n不碰：%s' "$from" "$duty" "$bound")
    reg_member "$from" active "intro"
    write_msg "$from" "" "自我介绍" "$body" group "-" "" "" "kind: intro" >/dev/null
    echo "$from 的自我介绍已发到群里"
}

# 表态：同一条议题上表态，re 指向被回应的消息 id
cmd_agree() {
    [ $# -ge 2 ] || { usage >&2; exit 2; }
    from=$(clean "$1"); re=$2; shift 2; note=${1:-同意}
    body="同意 $re${note:+：$note}"
    write_msg "$from" "" "表态" "$body" group "-" "" "" "kind: agree
re: $re" >/dev/null
    echo "$from 已对 $re 表态"
}

# 结论：把讨论收口，记一条 decision
cmd_decide() {
    [ $# -ge 2 ] || { usage >&2; exit 2; }
    from=$(clean "$1"); subj=$2; body=$(read_body)
    write_msg "$from" "" "$subj" "$body" group "-" "" "" "kind: decision" >/dev/null
    echo "结论已记录：$subj"
}

# 删掉 members/<名字> 这条名单记录（不碰它发过的消息）
cmd_forget() {
    [ $# -ge 1 ] || { usage >&2; exit 2; }
    if [ "$1" = "--force" ]; then shift; force=1; else force=0; fi
    [ $# -ge 1 ] || { usage >&2; exit 2; }
    name=$(clean "$1")
    # 机主是本人身份，误删会让 App/脚本的游标重新从头上算；要删必须显式 --force
    if [ "$name" = "机主" ] && [ "$force" = 0 ]; then
        echo "拒绝：机主是本人身份记录，要删请显式加 --force" >&2; exit 2
    fi
    if [ -f "$ROOT/members/$name" ]; then
        rm -f "$ROOT/members/$name"; echo "已删除成员记录：$name（消息未动）"
    else
        echo "（没有这条成员记录：$name）"
    fi
}

# 生成一段「开场白」，粘给某个会话即可让它知道自己在群里、以及怎么读怎么发
cmd_brief() {
    [ $# -ge 1 ] || { usage >&2; exit 2; }
    name=$(clean "$1"); dir=${2:-$ROOT}
    self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
    cat <<EOF
你在一个多会话共享的消息板里，你的名字是：$name
消息目录：$dir（一条消息一个 .msg 文件；没有服务器、没有推送、不会有人叫你）

每轮开头先看别人说了什么（只给未读，不含自己发的）：
  MSGBUS_DIR=$dir sh $self new $name

要发一条（首行 refs: 写 commit 或文件路径，正文尽量 ≤5 行）：
  printf 'refs: -\n<一句话>\n' | MSGBUS_DIR=$dir sh $self post $name

第一次接手时先对齐（摘要 + 未读 + 最近提交 + 项目表）：
  MSGBUS_DIR=$dir sh $self join $name

规矩：只用「$name」这个名字发言；不要替别人发；结论写进项目文档，群里只留过场。
路径提示：上面是 chroot 视角；在 Android 侧运行时把 /workspace 换成 /data/local/tmp/eta。
EOF
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
    # 对齐完把游标推到最新：之后 new 只给新消息，不会把历史再倒一遍
    newest=$(cd "$SPOOL" 2>/dev/null && ls -1 *.msg 2>/dev/null | tail -1 | sed 's/\.msg$//')
    if [ -n "$newest" ]; then mkdir -p "$SEEK"; printf '%s\n' "$newest" >> "$SEEK/$me"; fi

    echo "== 工作区最近提交"
    if command -v git >/dev/null 2>&1; then
        git -C "$W" log --oneline -8 2>/dev/null || echo "（$W 不是 git 仓库）"
    else
        echo "（当前环境没有 git：Android 侧读不到提交记录，请在 chroot 里跑）"
    fi
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
    intro) cmd_intro "$@" ;;
    agree) cmd_agree "$@" ;;
    decide) cmd_decide "$@" ;;
    join) cmd_join "$@" ;;
    leave) cmd_leave "$@" ;;
    members) cmd_members ;;
    forget) cmd_forget "$@" ;;
    brief) cmd_brief "$@" ;;
    send) cmd_send "$@" ;;
    list) cmd_list "$@" ;;
    read) cmd_read "$@" ;;
    all) cmd_all "$@" ;;
    help|-h|--help) usage ;;
    *) echo "未知命令：$cmd" >&2; usage >&2; exit 2 ;;
esac
