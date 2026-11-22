#!/bin/zsh
# Prépare le runtime iOS et les paquets Python utilisés par Xcode.
set -euo pipefail

ROOT="${0:A:h:h}"
PY_TAG="3.14-b11"
PY_ASSET="Python-3.14-iOS-support.b11.tar.gz"
PY_SHA256="b591f3301bd22a4f423c49c746cac9e55558b909fd14d6eb8327ccc62234ab7b"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

if [[ ! -d "$ROOT/Vendor/Python.xcframework" ]]; then
    echo "→ Python.xcframework ($PY_TAG)"
    curl -fLSs --retry 3 -o "$STAGING/$PY_ASSET" \
        "https://github.com/beeware/Python-Apple-support/releases/download/$PY_TAG/$PY_ASSET"
    (cd "$STAGING" && echo "$PY_SHA256  $PY_ASSET" | shasum -a 256 --check --status)
    tar xzf "$STAGING/$PY_ASSET" -C "$STAGING" Python.xcframework VERSIONS
    mkdir -p "$ROOT/Vendor"
    mv "$STAGING/VERSIONS" "$STAGING/Python.xcframework" "$ROOT/Vendor/"
fi

echo "→ Paquets Python embarqués"
python3 -m pip download --disable-pip-version-check --no-deps --only-binary=:all: \
    --require-hashes -r "$ROOT/scripts/requirements-ios.txt" -d "$STAGING/wheels"
mkdir "$STAGING/app_packages"
for wheel in "$STAGING"/wheels/*.whl; do
    unzip -q -o "$wheel" -d "$STAGING/app_packages"
done
# Les complétions shell et les pages de manuel sont réservées à la ligne de commande.
rm -rf "$STAGING"/app_packages/*.data(N)
rm -rf "$ROOT/python/app_packages"
mv "$STAGING/app_packages" "$ROOT/python/app_packages"
