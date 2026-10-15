package com.bobo.kotv

/** 本机 Go 引擎默认端口 / 根地址（与 Flutter kotvDefaultEnginePort、Go localproxy.DefaultPort 一致）。 */
object KotvEngineDefaults {
  const val PORT = 9978
  const val BASE_URL = "http://127.0.0.1:$PORT"
}
