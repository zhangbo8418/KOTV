# 内嵌字体（不进 git）

由仓库根目录执行：

```bash
./scripts/fetch-flutter-fonts.sh
# Win7 线额外拉黑白 emoji：
KOTV_WIN7=1 ./scripts/fetch-flutter-fonts.sh
```

| 文件 | 来源 | 约 | 谁用 |
|------|------|-----|------|
| `NotoSansSC-Regular.otf` / `Bold` | [Noto CJK Sans2.004](https://github.com/notofonts/noto-cjk/releases/tag/Sans2.004) | 8 + 8 MB | 各平台 |
| `NotoColorEmoji.ttf` | [noto-emoji](https://github.com/googlefonts/noto-emoji) `WindowsCompatible`（COLR） | 10 MB | Win10+ / 非 Win7 |
| `NotoEmoji.ttf` | [google/fonts](https://github.com/google/fonts) `ofl/notoemoji` 黑白轮廓 | 2 MB | **仅 Win7**（`adapt-flutter-win7-sdk.sh` 注入 pubspec） |

合计约 **26 MB**（+ Win7 约 2 MB）。各平台 `package-flutter-*.sh` 会自动拉取。

**Win7：** 无 Segoe UI Emoji，COLR 彩色常画不出；主题只用 `NotoEmoji`（黑白）。
