#!/usr/bin/env bash
#
# 把签名物料准备进一个临时 keychain —— 上架（App Store Connect）这条路唯一需要的
# 本地物料。逻辑只有这一份，`asc` / 以后的 `dmg` 都调它。
#
# 用法：
#   scripts/signing-setup.sh setup <CERT_ENV_VAR>...
#   scripts/signing-setup.sh teardown
#
# 证书用**环境变量名**传（值由调用方注入，脚本自己不读 secrets），密码按
# `<前缀>_BASE64` → `<前缀>_PASSWORD` 的约定自动推导。
# setup 结束后向 $GITHUB_ENV（若存在）写入：
#   SIGNING_KEYCHAIN   临时 keychain 的路径
#   ASC_KEY_PATH       AuthKey_<keyId>.p8 的路径
#   ASC_KEY_ID         App Store Connect API key id
#
# 为什么必须先「导入证书」（哪怕是上架）：GitHub 的 macOS runner 每次都是空
# keychain，而 `xcodebuild archive` 在 automatic 签名下会去要一张**开发**证书；
# 本地没有就请 Apple 现造一张 —— 那张的私钥随 runner 一起销毁、永远不能再用，
# 每跑一次烧一张，直到撞上 Apple 的证书上限。真实发生过：一天 10 张
# "Apple Development: Created via API"，之后所有构建都开始失败。
#
# 导入的通常是**合集** p12（开发 / 分发 / installer / Developer ID 全在里），
# 多个仓库共用一份。所以这里刻意**不查有效期、不挑身份**：合集里带着历史遗留的
# 过期证书是常态，拿它们拦发布只会误报；真要用的那张过期时，签名或导出那一步
# 会直接失败。

# 既能直接执行（CI 里作为一个独立 step），也能被 `source`（asc.sh 在同一进程里调它）。
# 后者是必须的：子进程 export 的变量传不回父进程，而 $GITHUB_ENV 只对**后续
# step** 生效 —— 同一进程里自己调自己时它一点用都没有。

set -euo pipefail

KEYCHAIN="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/apple-release-signing.keychain-db"
KEYCHAIN_PASSWORD=actions

fail() {
  echo "::error::$*" >&2
  exit 1
}

# $GITHUB_ENV 只在 Actions 里存在；本机跑的时候静默跳过。
# 同时 export 到当前进程：被 source 时（asc.sh）调用方要能直接读到这些值。
export_env() {
  if [ -n "${GITHUB_ENV:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_ENV"
  fi
  export "$1=$2"
}

# secret 里存的可能是「尾部 padding 被丢掉的 base64」，也可能直接就是 PEM。
# 不能只用 `base64 --decode`：它对残缺输入**静默丢字节** —— 踩过一次，少一个 '='
# 就丢 2 字节，PEM 结束行被砍成 `-----END PRIVATE KEY---`，结果 xcodebuild /
# notarytool 在几分钟后才报一个看不懂的 invalidPEMDocument。
decode_base64() {
  python3 -c 'import base64,sys; s=sys.argv[1].strip(); sys.stdout.buffer.write(s.encode()+b"\n" if "BEGIN PRIVATE KEY" in s else base64.b64decode(s+"="*(-len(s)%4)))' "$1"
}

teardown() {
  security delete-keychain "${SIGNING_KEYCHAIN:-$KEYCHAIN}" >/dev/null 2>&1 || true
  rm -rf "$HOME/private_keys"
  echo "已清理临时 keychain 与 ~/private_keys"
}

# 从 keychain 里挑一个可用的签名身份（打印它的全名）。直发（dmg）那条路要显式钉住
# 签名身份，上架（asc）那条路不需要（它的身份由 cloud signing 给）。
#
# 只看**有效**身份（-v）：合集里常有过期证书，同一个 CN 的过期/有效两张并存时，
# 不筛就会挑到过期的那张，然后要么签名失败、要么 automatic 签名转头去造一张新的。
signing_identity() {
  local fragment="${1:?signing_identity 需要一个身份名片段}"
  local valid names picked
  valid="$(security find-identity -v "${SIGNING_KEYCHAIN:-$KEYCHAIN}")"
  # 抠名字时不能假设行尾就是引号（不受信的身份后面会跟 `(CSSMERR_TP_NOT_TRUSTED)`、
  # 过期的跟 `(CSSMERR_TP_CERT_EXPIRED)`），所以只取第一对引号里的内容；
  # 同时直接滤掉带 CSSMERR_ 的那些 —— 无论如何都不应该挑到一个用不了的身份。
  names="$(printf '%s\n' "$valid" | grep -v 'CSSMERR_' | sed -n 's/^[[:space:]]*[0-9]*) [0-9A-Fa-f]\{1,\} "\([^"]*\)".*$/\1/p' || true)"
  # 末尾的 || true 不能省：没有匹配时 grep 返回 1，在 set -e + pipefail 下整个
  # 赋值语句会直接杀掉脚本，下面那句报错就没机会打出来（试过，真的是静默退出）。
  picked="$(printf '%s\n' "$names" | grep -F -- "$fragment" | head -1 || true)"
  [ -n "$picked" ] \
    || fail "keychain 里没有可用的 \"${fragment}\" 身份 —— 签名（以及依赖签名的那一步）需要它；缺了就只能让 Apple 现造一张。"
  printf '%s' "$picked"
}

setup() {
  local certs=()
  while [ $# -gt 0 ]; do
    certs+=("$1")
    shift
  done
  if [ ${#certs[@]} -eq 0 ] && [ -z "${APPLE_API_KEY:-}" ]; then
    fail "既没给证书环境变量，也没给 APPLE_API_KEY —— 那这一步只是准备了一个空 keychain"
  fi

  # 同一个 runner 上重跑（或者上一步失败留下的）时先清干净
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  # 默认几分钟就会自动锁；发布 job 动辄几十分钟，锁了必然失败。
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

  # 把临时 keychain 放到搜索列表最前面，而不是替换掉原列表：runner 上其它
  # keychain 还要能被解析到（信任链里的 Apple 根证书就在系统 keychain 里）。
  # 这里不能用 mapfile/readarray —— macOS 的 /bin/bash 卡在 3.2，两个内建都没有。
  local existing=()
  while IFS= read -r line; do
    existing+=("$line")
  done < <(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')
  if [ ${#existing[@]} -gt 0 ]; then
    security list-keychains -d user -s "$KEYCHAIN" "${existing[@]}"
  else
    security list-keychains -d user -s "$KEYCHAIN"
  fi
  security default-keychain -s "$KEYCHAIN"

  # 用 if 包住而不是直接 for：bash 3.2 在 `set -u` 下展开空数组会报
  # `certs[@]: unbound variable`（bash 4.4 才修）。
  local name pw_name value password dir
  if [ ${#certs[@]} -gt 0 ]; then
    for name in "${certs[@]}"; do
      case "$name" in
        *_BASE64) pw_name="${name%_BASE64}_PASSWORD" ;;
        *) pw_name="${name}_PASSWORD" ;;
      esac
      value="${!name:-}"
      password="${!pw_name:-}"
      [ -n "$value" ] || fail "$name 是空的（secret 没配？）"
      [ -n "$password" ] || fail "$pw_name 是空的（secret 被设成空值了？）"

      dir="$(mktemp -d)"
      decode_base64 "$value" >"$dir/cert.p12"

      # 导入的原始输出故意不重定向：它只有几行（"1 key imported" /
      # "1 certificate imported"），而一旦后面报错，这几行就是「到底是只有证书
      # 还是没带私钥」的唯一直接证据。
      #
      # -A：允许任何程序使用导入的私钥。这只是一次性 runner 上的一次性 keychain。
      # 换成一个一个 -T 点名（codesign/security/productbuild）看似更收敛，但少点
      # 一个（productbuild 没被信任）会让它**静默卡在**一个永远弹不出来的 keychain
      # 授权框上，最后以 job 超时收场 —— 已经踩过。
      security import "$dir/cert.p12" -P "$password" -f pkcs12 -A -k "$KEYCHAIN" \
        || fail "$name 导入失败（密码不对？或者 p12 里只有证书没有私钥？）"
      rm -rf "$dir"
    done
    # 空 keychain 上跑这条会直接报 "The specified item could not be found"，
    # 所以它必须待在导入之后。
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
  fi

  export_env SIGNING_KEYCHAIN "$KEYCHAIN"

  if [ -n "${APPLE_API_KEY:-}" ]; then
    [ -n "${APPLE_API_KEY_ID:-}" ] \
      || fail "APPLE_API_KEY_ID 是空的（secret 被设成空值了？）—— 文件名与 -authenticationKeyID 都会错。"
    mkdir -p "$HOME/private_keys"
    local key="$HOME/private_keys/AuthKey_${APPLE_API_KEY_ID}.p8"
    decode_base64 "$APPLE_API_KEY" >"$key"
    # 立刻验一遍，别让残缺的 base64 在几分钟后以 invalidPEMDocument 的形式暴露
    openssl pkey -in "$key" -noout \
      || fail "APPLE_API_KEY 解出来不是合法的 PKCS#8 私钥（$(wc -c <"$key" | tr -d ' ') 字节）。应该存 p8 文件的 base64（含结尾的 '='），或者直接存 PEM 全文。"
    chmod 600 "$key"
    local size sha
    size="$(wc -c <"$key" | tr -d ' ')"
    sha="$(shasum -a 256 "$key" | cut -c1-12)"
    # 注意这里花括号不能省：macOS 的 bash 3.2 在 UTF-8 locale 下会把紧跟其后的
    # 全角逗号当成变量名的一部分，直接报 `APPLE_API_KEY_ID，: unbound variable`。
    echo "::notice title=ASC API key::${APPLE_API_KEY_ID}，${size} 字节，sha256 ${sha}"
    export_env ASC_KEY_PATH "$key"
    export_env ASC_KEY_ID "$APPLE_API_KEY_ID"
  fi
}

# 直接执行时才走命令行分发；被 source 时只暴露函数（否则 sourcing 就会把 setup 跑一边）。
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "${1:-}" in
    setup)
      shift
      setup "$@"
      ;;
    teardown)
      teardown
      ;;
    *)
      fail "用法：$(basename "$0") setup [<CERT_ENV_VAR>...] | teardown"
      ;;
  esac
fi
