# 内嵌字体（不进 git）

由仓库根目录执行：

```bash
./scripts/fetch-flutter-fonts.sh
```

| 文件 | 来源 | 约 |
|------|------|-----|
| `NotoSansSC-Regular.otf` / `Bold` | [Noto CJK Sans2.004](https://github.com/notofonts/noto-cjk/releases/tag/Sans2.004) `18_NotoSansSC.zip` | 8 + 8 MB |
| `NotoColorEmoji.ttf` | [noto-emoji](https://github.com/googlefonts/noto-emoji) `NotoColorEmoji_WindowsCompatible.ttf` | 10 MB |

合计约 **26 MB**（SIL OFL）。各平台 `package-flutter-*.sh` 会自动拉取。
