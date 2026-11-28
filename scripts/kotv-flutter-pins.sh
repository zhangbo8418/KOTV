#!/usr/bin/env bash
# Flutter / DComp 版本钉死（脚本默认来源）。
# CI workflow 的 env 须与此保持一致；此处仅在环境变量未设置时填默认值。
#
# 分流：
#   FLUTTER_VERSION          非 Windows 主线（mac/linux/android/web/ios）
#   FLUTTER_WINDOWS_VERSION  Win8+ x64/arm64（须与 DComp 引擎 stamp 一致）
#   FLUTTER_WIN7_VERSION     Win7 实验线（官方最后支持 Win7 的稳定版）
#   KOTV_DCOMP_ENGINE_*      Win8+ 打包灌入的 DComp 引擎制品
#
# shellcheck disable=SC2034
: "${FLUTTER_VERSION:=3.50.1}"
: "${FLUTTER_WINDOWS_VERSION:=3.47.1}"
: "${FLUTTER_WIN7_VERSION:=3.19.6}"
: "${KOTV_DCOMP_ENGINE_TAG:=windows-v3.47.1+2}"
: "${KOTV_DCOMP_ENGINE_VER:=3.47.1}"
: "${KOTV_DCOMP_ENGINE_SHA256:=}"
: "${KOTV_DCOMP_ENGINE_URL_BASE:=https://github.com/edde746/flutter-plezy/releases/download}"

export FLUTTER_VERSION FLUTTER_WINDOWS_VERSION FLUTTER_WIN7_VERSION
export KOTV_DCOMP_ENGINE_TAG KOTV_DCOMP_ENGINE_VER KOTV_DCOMP_ENGINE_SHA256 KOTV_DCOMP_ENGINE_URL_BASE
