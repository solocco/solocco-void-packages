#!/bin/bash
set -euo pipefail

# Universal update script - dipanggil dari update-check.yml
# Usage: ./scripts/update.sh '<json config 1 package dari packages.json>'
# env opsional: GH_TOKEN (naikin rate limit GitHub API)

PKG_JSON="$1"

pkg=$(echo "$PKG_JSON" | jq -r '.package')
strategy=$(echo "$PKG_JSON" | jq -r '.strategy')
repo=$(echo "$PKG_JSON" | jq -r '.repo // empty')
template="srcpkgs/${pkg}/template"

AUTH_HEADER=()
if [ -n "${GH_TOKEN:-}" ]; then
  AUTH_HEADER=(-H "Authorization: Bearer ${GH_TOKEN}")
fi

gh_api() {
  curl -fsSL "${AUTH_HEADER[@]}" "https://api.github.com/$1"
}

# Versi "soft": TANPA -f, jadi HTTP 404/403 tetap balikin body JSON dengan
# exit 0 (curl gak nganggep HTTP error sebagai error tanpa -f). Ini penting
# buat probe yang boleh "gak ketemu": tanpa ini, curl -f exit non-zero ->
# pipefail bikin pipeline gagal -> set -e matiin script SEBELUM logika
# fallback/skip sempat jalan (mis. repo yang cuma punya tag tanpa release).
gh_api_soft() {
  curl -sSL "${AUTH_HEADER[@]}" "https://api.github.com/$1"
}

current_version() {
  grep -m1 '^version=' "$template" | cut -d= -f2 | tr -d '"'
}

set_version() {
  sed -i "s/^version=.*/version=$1/" "$template"
}

set_revision_1() {
  sed -i "s/^revision=.*/revision=1/" "$template"
}

emit_new_version() {
  echo "NEW_VERSION=$1" >> "$GITHUB_ENV"
}

# Download ke file lalu hash, supaya kegagalan curl (mis. 500/404) tidak
# ketelan oleh sha256sum dalam pipe (yang tetap sukses hash-in output kosong).
# Exit 1 kalau download gagal atau hasilnya file kosong.
download_and_checksum() {
  local url="$1"
  local tmpfile
  tmpfile=$(mktemp)
  if ! curl -fL --retry 3 --retry-delay 2 --retry-all-errors -s -o "$tmpfile" "$url"; then
    echo "Error: gagal download '$url'." >&2
    rm -f "$tmpfile"
    return 1
  fi
  if [ ! -s "$tmpfile" ]; then
    echo "Error: file hasil download kosong: '$url'." >&2
    rm -f "$tmpfile"
    return 1
  fi
  sha256sum "$tmpfile" | cut -d' ' -f1
  rm -f "$tmpfile"
}

echo "=== [$pkg] strategy: $strategy ==="

case "$strategy" in

  # ============ FONT (repo solocco/my-fonts, asset TTF + NerdFont) ============
  font)
    font_name=$(echo "$PKG_JSON" | jq -r '.font')
    src_repo="solocco/my-fonts"

    # gh_api_soft + penjaga `type=="array"`: kalau API balas body error
    # (object, mis. rate-limit 403), jangan sampai `.[]` bikin jq crash ->
    # pipefail -> set -e. Biar jatuh ke skip yang rapi di bawah.
    latest_ver=$(gh_api_soft "repos/${src_repo}/releases" | \
      jq -r --arg p "${font_name}-v" 'if type=="array" then ([.[] | select(.tag_name | startswith($p))] | .[0].tag_name // empty) else empty end' | \
      sed "s/${font_name}-v//")
    cur_ver=$(current_version)
    echo "Current: $cur_ver | Latest: $latest_ver"

    if [ -z "$latest_ver" ]; then
      echo "Tidak bisa dapat versi terbaru, skip"
      exit 0
    fi
    if [ "$latest_ver" = "$cur_ver" ]; then
      echo "Sudah up to date"
      exit 0
    fi

    base="https://github.com/${src_repo}/releases/download/${font_name}-v${latest_ver}"

    tmpttf=$(mktemp)
    tmpnerd=$(mktemp)
    if ! curl -fL --retry 3 --retry-delay 2 --retry-all-errors -s -o "$tmpttf" "${base}/${font_name}-TTF.tar.xz"; then
      echo "Error: gagal download TTF asset."
      rm -f "$tmpttf" "$tmpnerd"
      exit 1
    fi
    if ! curl -fL --retry 3 --retry-delay 2 --retry-all-errors -s -o "$tmpnerd" "${base}/${font_name}-NerdFont.tar.xz"; then
      echo "Error: gagal download NerdFont asset."
      rm -f "$tmpttf" "$tmpnerd"
      exit 1
    fi
    if [ ! -s "$tmpttf" ] || [ ! -s "$tmpnerd" ]; then
      echo "Error: salah satu file hasil download kosong."
      rm -f "$tmpttf" "$tmpnerd"
      exit 1
    fi
    cs1=$(sha256sum "$tmpttf"  | cut -d' ' -f1)
    cs2=$(sha256sum "$tmpnerd" | cut -d' ' -f1)
    rm -f "$tmpttf" "$tmpnerd"

    set_version "$latest_ver"
    # Versi baru -> revision balik ke 1 (konvensi Void), konsisten dengan
    # strategi lain. Cuma kejalan pas versi emang berubah (ada guard "up to
    # date" di atas), jadi bump revision manual di antara rilis tetap aman.
    set_revision_1
    python3 - "$template" "$cs1" "$cs2" <<'PYEOF'
import sys, re
path, cs1, cs2 = sys.argv[1:]
with open(path) as f:
    content = f.read()
new_checksum = f'checksum="{cs1}\n {cs2}"'
content = re.sub(r'checksum="[^"]*"', new_checksum, content, flags=re.DOTALL)
with open(path, 'w') as f:
    f.write(content)
PYEOF
    echo "Template updated ke $latest_ver"
    emit_new_version "$latest_ver"
    ;;

  # ============ SOURCE TARBALL (archive/refs/tags/<tag>.tar.gz) ============
  source-tarball)
    dash_strip=$(echo "$PKG_JSON" | jq -r '.dash_strip // false')
    set_tag_var=$(echo "$PKG_JSON" | jq -r '.set_tag_var // false')
    reset_rev=$(echo "$PKG_JSON" | jq -r '.reset_revision // true')
    fallback_tags=$(echo "$PKG_JSON" | jq -r '.fallback_tags // false')

    # Pakai gh_api_soft: repo tanpa GitHub Release resmi bakal balas 404 di
    # endpoint releases/latest. Dengan curl -f biasa, 404 itu matiin script
    # (set -e) sebelum fallback ke tags kejangkau -- bikin fallback_tags
    # jadi dead code.
    latest_tag=$(gh_api_soft "repos/${repo}/releases/latest" | jq -r '.tag_name // empty')
    if [ -z "$latest_tag" ] && [ "$fallback_tags" = "true" ]; then
      latest_tag=$(gh_api_soft "repos/${repo}/tags" | jq -r 'if type=="array" then (.[0].name // empty) else empty end')
    fi
    if [ -z "$latest_tag" ]; then
      echo "Gagal ambil tag terbaru, skip"
      exit 0
    fi

    latest_ver="${latest_tag#v}"
    if [ "$dash_strip" = "true" ]; then
      latest_ver=$(echo "$latest_ver" | tr -d '-')
    fi

    cur_ver=$(current_version)
    echo "Current: $cur_ver | Latest: $latest_ver (tag $latest_tag)"

    if [ "$latest_ver" = "$cur_ver" ]; then
      echo "Sudah up to date"
      exit 0
    fi

    tarball_url="https://github.com/${repo}/archive/refs/tags/${latest_tag}.tar.gz"
    if ! new_checksum=$(download_and_checksum "$tarball_url"); then
      echo "Error: gagal download/hash tarball."
      exit 1
    fi

    set_version "$latest_ver"
    [ "$reset_rev" = "true" ] && set_revision_1
    if [ "$set_tag_var" = "true" ]; then
      sed -i "s/^_tag=.*/_tag=\"${latest_tag}\"/" "$template"
    fi
    sed -i "s/^checksum=.*/checksum=${new_checksum}/" "$template"

    echo "Template updated ke $latest_ver"
    emit_new_version "$latest_ver"
    ;;

  # ============ GITEA / FORGEJO (host selain GitHub, mis. git.outfoxxed.me) ============
  gitea)
    host=$(echo "$PKG_JSON" | jq -r '.host')          # mis. git.outfoxxed.me
    reset_rev=$(echo "$PKG_JSON" | jq -r '.reset_revision // true')
    fallback_tags=$(echo "$PKG_JSON" | jq -r '.fallback_tags // true')

    if [ -z "$host" ] || [ "$host" = "null" ] || [ -z "$repo" ]; then
      echo "Error: strategy gitea butuh 'host' dan 'repo'."
      exit 1
    fi

    # Gitea/Forgejo API mirip GitHub: /api/v1/repos/<repo>/releases/latest &
    # /tags. Soft (tanpa -f) supaya 404 di releases/latest gak matiin script
    # sebelum fallback ke tags.
    gitea_soft() { curl -sSL "https://${host}/api/v1/$1"; }

    latest_tag=$(gitea_soft "repos/${repo}/releases/latest" | jq -r '.tag_name // empty' 2>/dev/null)
    if [ -z "$latest_tag" ] && [ "$fallback_tags" = "true" ]; then
      latest_tag=$(gitea_soft "repos/${repo}/tags" | jq -r 'if type=="array" then (.[0].name // empty) else empty end' 2>/dev/null)
    fi
    if [ -z "$latest_tag" ]; then
      echo "Gagal ambil tag terbaru dari $host, skip"
      exit 0
    fi

    latest_ver="${latest_tag#v}"
    cur_ver=$(current_version)
    echo "Current: $cur_ver | Latest: $latest_ver (tag $latest_tag)"

    if [ "$latest_ver" = "$cur_ver" ]; then
      echo "Sudah up to date"
      exit 0
    fi

    tarball_url="https://${host}/${repo}/archive/${latest_tag}.tar.gz"
    if ! new_checksum=$(download_and_checksum "$tarball_url"); then
      echo "Error: gagal download/hash tarball dari $host."
      exit 1
    fi

    set_version "$latest_ver"
    [ "$reset_rev" = "true" ] && set_revision_1
    sed -i "s/^checksum=.*/checksum=${new_checksum}/" "$template"

    echo "Template updated ke $latest_ver"
    emit_new_version "$latest_ver"
    ;;

  # ============ BINARY ASSET (1 asset prebuilt, download + hash) ============
  binary-asset)
    asset_template=$(echo "$PKG_JSON" | jq -r '.asset')
    url_v_prefix=$(echo "$PKG_JSON" | jq -r '.url_v_prefix // false')
    quoted=$(echo "$PKG_JSON" | jq -r '.quoted_checksum // true')

    latest_tag=$(gh_api_soft "repos/${repo}/releases/latest" | jq -r '.tag_name // empty')
    if [ -z "$latest_tag" ]; then
      echo "Gagal ambil versi terbaru, skip"
      exit 0
    fi
    latest_ver="${latest_tag#v}"
    cur_ver=$(current_version)
    echo "Current: $cur_ver | Latest: $latest_ver"

    if [ "$latest_ver" = "$cur_ver" ]; then
      echo "Sudah up to date"
      exit 0
    fi

    asset_name="${asset_template//\{version\}/$latest_ver}"
    if [ "$url_v_prefix" = "true" ]; then
      dl_path="v${latest_ver}"
    else
      dl_path="${latest_ver}"
    fi
    download_url="https://github.com/${repo}/releases/download/${dl_path}/${asset_name}"

    echo "Fetching checksum from: $download_url"
    if ! checksum=$(download_and_checksum "$download_url"); then
      echo "Error: gagal download/hash asset."
      exit 1
    fi

    set_version "$latest_ver"
    set_revision_1
    if [ "$quoted" = "true" ]; then
      sed -i "s/^checksum=.*/checksum=\"$checksum\"/" "$template"
    else
      sed -i "s/^checksum=.*/checksum=$checksum/" "$template"
    fi

    echo "Template updated ke $latest_ver"
    emit_new_version "$latest_ver"
    ;;

  # ============ BRAVE ORIGIN (cari release yg punya asset .rpm x86_64) ============
  brave)
    src_repo="brave/brave-browser"
    latest_ver=$(gh_api_soft "repos/${src_repo}/releases?per_page=50" | \
      jq -r 'if type=="array" then ([.[] | select(.prerelease == false) | select(any(.assets[]; .name | test("^brave-origin-[0-9].*x86_64\\.rpm$")))] | first | .tag_name // empty) else empty end' | \
      sed 's/^v//')
    if [ -z "$latest_ver" ] || [ "$latest_ver" = "null" ]; then
      echo "Error: gagal ambil versi terbaru."
      exit 1
    fi
    cur_ver=$(current_version)
    echo "Current: $cur_ver | Latest: $latest_ver"

    if [ "$latest_ver" = "$cur_ver" ]; then
      echo "Sudah up to date"
      exit 0
    fi

    url=$(gh_api_soft "repos/${src_repo}/releases?per_page=50" | \
      jq -r --arg v "v${latest_ver}" 'if type=="array" then ([.[] | select(.tag_name == $v)] | first | .assets[] | select(.name | test("^brave-origin-[0-9].*x86_64\\.rpm$")) | .browser_download_url) else empty end')
    if [ -z "$url" ]; then
      echo "Error: RPM asset tidak ketemu di release v${latest_ver}."
      exit 1
    fi

    if ! checksum=$(download_and_checksum "$url"); then
      echo "Error: gagal download/hash RPM asset."
      exit 1
    fi

    set_version "$latest_ver"
    set_revision_1
    sed -i "s/^checksum=.*/checksum=\"$checksum\"/" "$template"

    echo "Template updated ke $latest_ver"
    emit_new_version "$latest_ver"
    ;;

  # ============ GOOGLE CHROME (chromiumdash API, bukan GitHub) ============
  chrome)
    latest_ver=$(curl -s "https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Linux&num=1" | \
      grep -oP '"version":"\K[^"]+' | head -1)
    if [ -z "$latest_ver" ]; then
      echo "Error: gagal ambil versi terbaru."
      exit 1
    fi
    cur_ver=$(current_version)
    echo "Current: $cur_ver | Latest: $latest_ver"

    if [ "$latest_ver" = "$cur_ver" ]; then
      echo "Sudah up to date"
      exit 0
    fi

    deb_url="https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-stable/google-chrome-stable_${latest_ver}-1_amd64.deb"
    if ! checksum=$(download_and_checksum "$deb_url"); then
      echo "Error: gagal download/hash deb."
      exit 1
    fi

    set_version "$latest_ver"
    set_revision_1
    sed -i "s/^checksum=.*/checksum=$checksum/" "$template"

    echo "Template updated ke $latest_ver"
    emit_new_version "$latest_ver"
    ;;

  # ============ STATIC (no upstream versioning, manual-only package) ============
  static)
    echo "Package static (no version tracking), skip."
    exit 0
    ;;

  *)
    echo "Strategy tidak dikenal: $strategy"
    exit 1
    ;;
esac
