#!/usr/bin/env bash
# prepare-metallib.sh
#
# Готовит mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib рядом
# с executable, который собирает `swift run FoodEval`.
#
# Зачем: SwiftPM CLI (`swift build`) не компилирует .metal-исходники из Cmlx
# target — Xcode делает это в своей build-phase. Без metallib любая попытка
# обратиться к MLX.Device бросает SIGABRT в C++ стеке ("Failed to load the
# default metallib"). Wave 1 это пометил как gap; здесь — закрытие.
#
# Как: один раз собираем eval-tool через `xcodebuild` (он генерит macOS-
# вариант metallib). Потом симлинкуем готовый bundle в .build/.../debug/,
# куда `swift run` кладёт executable. mlx-swift load_swiftpm_library ищет
# bundle через NS::Bundle::mainBundle() (CLI executable directory) — линка
# хватает, повторное копирование не нужно.
#
# Идемпотентен: при повторном запуске не пересобирает и не перелинковывает,
# если ссылка уже валидна.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SWIFT_BIN_DIR="$EVAL_ROOT/.build/arm64-apple-macosx/debug"
BUNDLE_NAME="mlx-swift_Cmlx.bundle"
TARGET_BUNDLE="$SWIFT_BIN_DIR/$BUNDLE_NAME"

# 0) Если bundle уже на месте и непустой — выходим.
if [[ -e "$TARGET_BUNDLE" ]]; then
    METALLIB_PATH="$TARGET_BUNDLE/Contents/Resources/default.metallib"
    if [[ -L "$TARGET_BUNDLE" || -d "$TARGET_BUNDLE" ]] && [[ -f "$METALLIB_PATH" ]]; then
        echo "[prepare-metallib] OK: $TARGET_BUNDLE already in place"
        exit 0
    fi
fi

# 1) Гарантируем, что .build/...debug/ существует.
mkdir -p "$SWIFT_BIN_DIR"

# 2) Если metallib bundle уже собран Xcode'ом — ищем готовый.
EXISTING="$(find "$HOME/Library/Developer/Xcode/DerivedData" -name "$BUNDLE_NAME" -path "*Build/Products/Debug/*" -type d 2>/dev/null | head -1)"

if [[ -z "$EXISTING" ]]; then
    echo "[prepare-metallib] No prebuilt $BUNDLE_NAME in DerivedData; building via xcodebuild..."
    pushd "$EVAL_ROOT" >/dev/null
    xcodebuild \
        -scheme FoodEval \
        -destination 'platform=macOS,arch=arm64' \
        -configuration Debug \
        build 2>&1 | tail -5
    popd >/dev/null

    EXISTING="$(find "$HOME/Library/Developer/Xcode/DerivedData" -name "$BUNDLE_NAME" -path "*Build/Products/Debug/*" -type d 2>/dev/null | head -1)"

    if [[ -z "$EXISTING" ]]; then
        echo "[prepare-metallib] ERROR: failed to locate $BUNDLE_NAME after xcodebuild" >&2
        exit 1
    fi
fi

echo "[prepare-metallib] Found Xcode bundle: $EXISTING"

# 3) Симлинкуем (rm-old + ln). cp -R — fallback при невозможности симлинкнуть.
rm -rf "$TARGET_BUNDLE"
ln -s "$EXISTING" "$TARGET_BUNDLE"
echo "[prepare-metallib] Linked $TARGET_BUNDLE -> $EXISTING"
