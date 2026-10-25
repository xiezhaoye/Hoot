# Hoot 产品落地页

https://hoot.xiezhaoye.site

沿用 XMark 的 Cloudflare Workers 静态资源 + 自定义域名部署方式。应用安装包由 GitHub Releases 托管，不占用站点资源。

## 本地预览

```bash
node landing/build.mjs
python3 -m http.server 4311 --directory landing/dist
```

访问 http://localhost:4311。

## 部署

使用已授权的 Cloudflare 账号与 Wrangler CLI：

```bash
cd landing
node build.mjs
wrangler deploy
```

Worker 名称 `hoot-site`，域名 `hoot.xiezhaoye.site`。不修改 XMark 的 Worker、域名或 R2 桶。

- `index.html` / `style.css` / `site.js`：落地页，无运行时依赖与追踪脚本。
- `assets/logo.png`：从项目原有 AppIcon.icns 导出。
- `assets/hoot-editor.jpg`：使用用户提供的标注图片，在隔离历史目录中运行实际 Hoot 界面所得截图。
- `assets/annotation-example.png`：用户指定的产品介绍图。
- `wrangler.jsonc`：部署配置。

发布新版时更新页面中的版本号、下载 URL 和更新记录，并发布对应 GitHub Release。`dist/` 是生成目录，不入 Git。

凭据留在系统授权存储中，不复制进仓库。CI 如需自动部署，应单独配置项目最小权限 API Token，不复用本机 OAuth。
