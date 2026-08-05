# 内嵌字体（不进 git，**仅 Win7 线**）

其它平台用系统字体，不内嵌、不拉取。

Win7 打包前（仓库根目录）：

```bash
KOTV_WIN7=1 ./scripts/fetch-flutter-fonts.sh
# 或由 package-flutter-windows.sh（KOTV_WIN7=1）自动调用
```

| 文件 | 来源 | 约 |
|------|------|-----|
| `NotoSansSC-Regular.otf` / `Bold` | [Noto CJK Sans2.004](https://github.com/notofonts/noto-cjk/releases/tag/Sans2.004) | 8 + 8 MB |
| `NotoColorEmoji.ttf` | [noto-emoji](https://github.com/googlefonts/noto-emoji) COLR | 10 MB |
| `NotoEmoji.ttf` | [google/fonts](https://github.com/google/fonts) `ofl/notoemoji` 黑白 | 2 MB |

`adapt-flutter-win7-sdk.sh` 向 pubspec 注入上述 fonts；主题在 Win7 上用 `NotoEmoji`（黑白），因 COLR 彩色常渲不出。
