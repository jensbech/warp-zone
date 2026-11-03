#!/usr/bin/env bash
set -euo pipefail

catalog="${CATALOG:-/usr/local/share/warp-zone/catalog.json}"
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/go/bin:/usr/local/cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
export RUSTUP_HOME="${RUSTUP_HOME:-/usr/local/rustup}"

dpkg_arch="$(dpkg --print-architecture)"
case "$dpkg_arch" in
  amd64 | arm64) ;;
  *) printf 'install-tools: unsupported architecture %s\n' "$dpkg_arch" >&2; exit 1 ;;
esac
. /etc/os-release

work="$(mktemp -d)"
mkdir -p "$work/spec" "$work/log" "$work/status"
trap 'rm -rf "$work"' EXIT

log() { printf '==> %s\n' "$*"; }
die() { printf 'install-tools: %s\n' "$*" >&2; exit 1; }

curl_get() { curl -fsSL --retry 4 --retry-delay 2 --retry-connrefused "$@"; }

id_to_var() { printf '%s' "$1" | tr 'a-z-' 'A-Z_'; }

load_vars() {
  local pair
  while IFS= read -r pair; do
    export "$pair"
  done < <(jq -r '.vars | to_entries[] | "\(.key)=\(.value)"' "$catalog")
  for pair in ${TOOL_VERSIONS:-}; do
    case "$pair" in
      *=*) export "$pair" ;;
    esac
  done
}

spec_of() { printf '%s/spec/%s.json' "$work" "$1"; }

want=" "
add_id() {
  local id="$1" req
  case "$want" in *" $id "*) return 0 ;; esac
  if ! jq -ce --arg id "$id" '.tools[] | select(.id == $id)' "$catalog" > "$(spec_of "$id")" 2>/dev/null || [ ! -s "$(spec_of "$id")" ]; then
    printf 'install-tools: warning: unknown tool "%s" ignored\n' "$id" >&2
    return 0
  fi
  want="$want$id "
  for req in $(jq -r '.requires // [] | .[]' "$(spec_of "$id")"); do
    add_id "$req"
  done
}

select_tools() {
  local id var
  for id in ${TOOLS:-}; do add_id "$id"; done
  for var in ${LEGACY_INCLUDES:-}; do
    id="$(printf '%s' "${var#INCLUDE_}" | tr 'A-Z_' 'a-z-')"
    add_id "$id"
  done
}

methods_of() { jq -c 'if (.install | type) == "array" then .install[] else .install end' "$(spec_of "$1")"; }
field() { jq -r --arg k "$1" '.[$k] // empty' <<< "$2"; }

fill_template() {
  local text="$1" keyring="$2"
  text="${text//\{arch\}/$dpkg_arch}"
  text="${text//\{keyring\}/$keyring}"
  text="${text//\{codename\}/${VERSION_CODENAME:-}}"
  text="${text//\{id\}/$ID}"
  text="${text//\{version_id\}/$VERSION_ID}"
  text="${text//\{NODE_MAJOR\}/${NODE_MAJOR:-24}}"
  printf '%s' "$text"
}

add_repo() {
  local name="$1" repo keyname keyring key line
  [ -e "$work/repo-$name" ] && return 0
  repo="$(jq -c --arg n "$name" '.repos[$n]' "$catalog")"
  keyname="$(jq -r '.keyring // empty' <<< "$repo")"
  keyring="/etc/apt/keyrings/${keyname:-$name}.gpg"
  mkdir -p /etc/apt/keyrings
  if [ ! -f "$keyring" ]; then
    key="$(jq -r '.key' <<< "$repo")"
    if [ "$(jq -r '.dearmor' <<< "$repo")" = "true" ]; then
      curl_get "$key" | gpg --dearmor -o "$keyring"
    else
      curl_get "$key" -o "$keyring"
    fi
    chmod go+r "$keyring"
  fi
  line="$(fill_template "$(jq -r '.line' <<< "$repo")" "$keyring")"
  printf '%s\n' "$line" > "/etc/apt/sources.list.d/warp-$name.list"
  : > "$work/repo-$name"
}

apt_available() {
  local pkg
  for pkg in $1; do
    apt-cache show "$pkg" > /dev/null 2>&1 || return 1
  done
}

latest_github_tag() {
  local url
  url="$(curl_get -I -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest")"
  printf '%s' "${url##*/}"
}

resolve_version() {
  local id="$1" method="$2" var version gh tag_prefix latest_url latest_jq
  var="$(id_to_var "$id")_VERSION"
  version="${!var:-}"
  [ -n "$version" ] || version="$(field version "$method")"
  if [ -z "$version" ]; then
    latest_url="$(jq -r '.latest.url // empty' <<< "$method")"
    gh="$(field gh "$method")"
    if [ -n "$latest_url" ]; then
      latest_jq="$(jq -r '.latest.jq' <<< "$method")"
      version="$(curl_get "$latest_url" | jq -r "$latest_jq")"
    elif [ -n "$gh" ]; then
      version="$(latest_github_tag "$gh")"
      tag_prefix="$(field tag_prefix "$method")"
      version="${version#"$tag_prefix"}"
    fi
  fi
  version="${version#v}"
  printf '%s' "$version"
}

release_url() {
  local id="$1" method="$2" url version arch_name
  url="$(field release "$method")"
  case "$url" in
    *'{version}'*)
      version="$(resolve_version "$id" "$method")"
      [ -n "$version" ] || die "$id: could not determine a version (set $(id_to_var "$id")_VERSION in profile.env)"
      url="${url//\{version\}/$version}"
      ;;
  esac
  arch_name="$(jq -r --arg a "$dpkg_arch" '.arch[$a] // $a' <<< "$method")"
  url="${url//\{arch\}/$arch_name}"
  printf '%s' "$url"
}

extract_archive() {
  local file="$1" url="$2" dest="$3"
  mkdir -p "$dest"
  case "${url%%\?*}" in
    *.tar.gz | *.tgz) tar -xzf "$file" -C "$dest" ;;
    *.tar.xz) tar -xJf "$file" -C "$dest" ;;
    *.tar.bz2) tar -xjf "$file" -C "$dest" ;;
    *.zip) unzip -q "$file" -d "$dest" ;;
    *) return 1 ;;
  esac
}

install_release() {
  local id="$1" method="$2" url tmp file src dir link bins first pattern found f name
  url="$(release_url "$id" "$method")"
  tmp="$(mktemp -d "$work/dl.XXXXXX")"
  file="$tmp/download"
  curl_get "$url" -o "$file"
  bins="$(field bin "$method")"
  dir="$(field dir "$method")"
  if extract_archive "$file" "$url" "$tmp/x"; then
    src="$tmp/x"
    if [ -n "$dir" ]; then
      if [ "$(find "$src" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = "1" ] && [ -d "$(find "$src" -mindepth 1 -maxdepth 1)" ]; then
        src="$(find "$src" -mindepth 1 -maxdepth 1)"
      fi
      rm -rf "$dir"
      mkdir -p "$(dirname "$dir")"
      mv "$src" "$dir"
      chmod -R a+rX "$dir"
      for link in $(field link "$method"); do
        ln -sf "$dir/$link" "/usr/local/bin/$(basename "$link")"
      done
    else
      for pattern in $bins; do
        found=0
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          install -m 0755 "$f" "/usr/local/bin/$(basename "$f")"
          found=1
          case "$pattern" in *'*'*) ;; *) break ;; esac
        done < <(find "$src" -type f -name "$pattern" | sort)
        [ "$found" = "1" ] || die "$id: no file named $pattern inside $url"
      done
    fi
  else
    [ -n "$bins" ] || die "$id: $url is not an archive and no bin name was given"
    first="${bins%% *}"
    install -m 0755 "$file" "/usr/local/bin/$first"
    for name in ${bins#"$first"}; do
      ln -sf "/usr/local/bin/$first" "/usr/local/bin/$name"
    done
  fi
  rm -rf "$tmp"
}

install_script_rust() {
  export RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
  curl --proto '=https' --tlsv1.2 -fsSL --retry 4 https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal --default-toolchain stable
  chmod -R a+w "$RUSTUP_HOME" "$CARGO_HOME"
}

install_script_bun() {
  curl_get https://bun.sh/install | BUN_INSTALL=/usr/local bash
}

install_script_aws_cli() {
  local aws_arch tmp
  case "$dpkg_arch" in
    arm64) aws_arch=aarch64 ;;
    *) aws_arch=x86_64 ;;
  esac
  tmp="$(mktemp -d "$work/aws.XXXXXX")"
  curl_get "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip" -o "$tmp/awscliv2.zip"
  unzip -q "$tmp/awscliv2.zip" -d "$tmp"
  "$tmp/aws/install" --update
  rm -rf "$tmp"
}

install_method() {
  local id="$1" method="$2" script
  if [ -n "$(field release "$method")" ]; then
    install_release "$id" "$method"
  elif [ -n "$(field script "$method")" ]; then
    script="install_script_$(field script "$method" | tr '-' '_')"
    "$script"
  fi
}

run_post() {
  local post
  post="$(field post "$1")"
  [ -z "$post" ] || bash -euo pipefail -c "$post"
}

job_start() {
  local id="$1"
  shift
  (
    set +e
    (
      set -e
      "$@"
    ) > "$work/log/$id.log" 2>&1
    printf '%s' "$?" > "$work/status/$id"
  ) &
}

job_wait_slot() {
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "${INSTALL_JOBS:-8}" ]; do
    sleep 0.3
  done
}

job_report() {
  local id rc bad=0
  for id in "$@"; do
    rc="$(cat "$work/status/$id" 2> /dev/null || echo 1)"
    if [ "$rc" = "0" ]; then
      log "installed $id"
    else
      bad=1
      printf '\n--- %s failed (exit %s) ---\n' "$id" "$rc" >&2
      cat "$work/log/$id.log" >&2
    fi
  done
  [ "$bad" = "0" ] || die "one or more tools failed to install"
}

run_parallel() {
  local id
  for id in "$@"; do
    job_wait_slot
    job_start "$id" install_one "$id"
  done
  wait
  job_report "$@"
}

install_one() {
  local id="$1" method
  while IFS= read -r method; do
    install_method "$id" "$method"
    run_post "$method"
  done < <(chosen_methods "$id")
}

chosen_methods() {
  [ -f "$work/chosen-$1" ] && cat "$work/chosen-$1"
  return 0
}

install_npm() {
  local pkgs=("$@")
  export NPM_CONFIG_UPDATE_NOTIFIER=false NPM_CONFIG_FUND=false NPM_CONFIG_AUDIT=false
  npm install -g "${pkgs[@]}"
  npm cache clean --force > /dev/null 2>&1 || true
}

install_uv_tools() {
  local id method pkg py
  export UV_TOOL_DIR=/opt/uv/tools UV_TOOL_BIN_DIR=/usr/local/bin UV_PYTHON_INSTALL_DIR=/opt/uv/python UV_NO_CACHE=1
  mkdir -p "$UV_TOOL_DIR" "$UV_PYTHON_INSTALL_DIR"
  for id in "$@"; do
    method="$(methods_of "$id" | head -n1)"
    pkg="$(field uv "$method")"
    py="$(field python "$method")"
    log "uv tool install $pkg"
    if [ -n "$py" ]; then
      uv tool install --python "$py" "$pkg"
    else
      uv tool install "$pkg"
    fi
  done
  chmod -R a+rX /opt/uv
}

verify_tools() {
  local id check bad=0 out
  for id in "$@"; do
    check="$(jq -r '.check // empty' "$(spec_of "$id")")"
    [ -n "$check" ] || continue
    if ! out="$(cd /tmp && bash -c "$check" 2>&1)"; then
      bad=1
      printf '\n--- %s installed but its check failed: %s ---\n%s\n' "$id" "$check" "$out" >&2
    fi
  done
  [ "$bad" = "0" ] || die "post-install verification failed"
}

main() {
  local id method kind apt_packages="" pkgs parallel_ids="" npm_pkgs="" uv_ids="" need_update missing=""
  load_vars
  select_tools

  if [ "$want" = " " ] && [ -z "${EXTRA_APT_PACKAGES:-}" ]; then
    log "no optional tools selected"
    exit 0
  fi
  log "selected:${want}${EXTRA_APT_PACKAGES:+ (+ apt: $EXTRA_APT_PACKAGES)}"

  for id in $want; do
    while IFS= read -r method; do
      [ -z "$(field repo "$method")" ] || add_repo "$(field repo "$method")"
    done < <(methods_of "$id")
  done

  need_update=false
  for id in $want; do
    while IFS= read -r method; do
      [ -z "$(field apt "$method")" ] || need_update=true
    done < <(methods_of "$id")
  done
  [ -z "${EXTRA_APT_PACKAGES:-}" ] || need_update=true
  [ "$need_update" = "false" ] || apt-get update

  for id in $want; do
    : > "$work/chosen-$id"
    while IFS= read -r method; do
      kind=""
      [ -z "$(field apt "$method")" ] || kind=apt
      [ -z "$(field release "$method")" ] || kind=release
      [ -z "$(field npm "$method")" ] || kind=npm
      [ -z "$(field uv "$method")" ] || kind=uv
      [ -z "$(field script "$method")" ] || kind=script
      [ -z "$(field stage "$method")" ] || kind=stage
      if [ -s "$work/chosen-$id" ] || [ -e "$work/done-$id" ]; then
        break
      fi
      case "$kind" in
        apt)
          pkgs="$(field apt "$method")"
          if apt_available "$pkgs"; then
            apt_packages="$apt_packages $pkgs"
            printf '%s\n' "$method" | jq -c '{post: .post}' > "$work/apt-post-$id"
            : > "$work/done-$id"
          fi
          ;;
        npm)
          npm_pkgs="$npm_pkgs $(field npm "$method")"
          : > "$work/done-$id"
          ;;
        uv)
          uv_ids="$uv_ids $id"
          : > "$work/done-$id"
          ;;
        stage)
          : > "$work/done-$id"
          ;;
        release | script)
          printf '%s\n' "$method" > "$work/chosen-$id"
          parallel_ids="$parallel_ids $id"
          ;;
      esac
    done < <(methods_of "$id")
    if [ ! -s "$work/chosen-$id" ] && [ ! -e "$work/done-$id" ]; then
      missing="$missing $id"
    fi
  done
  [ -z "$missing" ] || die "no install method is available on ${PRETTY_NAME:-$ID} ($dpkg_arch) for:$missing"
  if [ "${PLAN_ONLY:-}" = "1" ]; then
    log "plan ok on ${PRETTY_NAME:-$ID} ($dpkg_arch)"
    exit 0
  fi

  apt_packages="$apt_packages ${EXTRA_APT_PACKAGES:-}"
  if [ -n "${apt_packages// /}" ]; then
    log "apt-get install:${apt_packages}"
    # shellcheck disable=SC2086
    apt-get install -y --no-install-recommends $apt_packages
  fi
  rm -rf /var/lib/apt/lists/*

  for id in $want; do
    if [ -f "$work/apt-post-$id" ]; then
      run_post "$(cat "$work/apt-post-$id")"
    fi
  done

  # shellcheck disable=SC2086
  [ -z "$parallel_ids" ] || run_parallel $parallel_ids

  if [ -n "$npm_pkgs" ]; then
    log "npm install -g:${npm_pkgs}"
    # shellcheck disable=SC2086
    install_npm $npm_pkgs
  fi
  # shellcheck disable=SC2086
  [ -z "$uv_ids" ] || install_uv_tools $uv_ids

  # shellcheck disable=SC2086
  verify_tools $want
  rm -rf /root/.cache /root/.npm 2> /dev/null || true
  log "done"
}

main "$@"
