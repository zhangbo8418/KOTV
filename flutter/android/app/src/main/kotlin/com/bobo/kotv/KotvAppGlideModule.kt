package com.bobo.kotv

import com.bumptech.glide.annotation.GlideModule
import com.bumptech.glide.module.AppGlideModule

/**
 * 禁用 Manifest 解析 GlideModule。
 *
 * 站点 jar 会临时包名为 `com.fongmi.android.tv`；若盒子上同时装了 TV，
 * Glide 会去读 TV 的 meta-data（如 OkHttpGlideModule），本 APK 没有该类 →
 * 海报 PlatformView 全挂，首页看起来像「黑屏/空壳」。
 */
@GlideModule
class KotvAppGlideModule : AppGlideModule() {
  override fun isManifestParsingEnabled(): Boolean = false
}
