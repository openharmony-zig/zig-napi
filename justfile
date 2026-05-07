set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

init:
    npm install --global @ohos-rs/oxk @j178/prek
    prek validate-config prek.toml
    prek install --config prek.toml --hook-type pre-commit --prepare-hooks --overwrite

build-example:
    #!/usr/bin/env bash
    set -euo pipefail

    targets=(
      aarch64-linux-ohos
      arm-linux-ohoseabi
      x86_64-linux-ohos
    )

    for example in examples/*; do
      [[ -f "$example/build.zig" ]] || continue

      for target in "${targets[@]}"; do
        echo "==> $example ($target)"
        (cd "$example" && zig build -Dtarget="$target")
      done
    done

format:
    zig fmt $(git ls-files '*.zig' '*.zon')
    oxk format $(git ls-files '*.js' '*.jsx' '*.ts' '*.tsx' '*.ets')
