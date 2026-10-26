import { createHash } from "node:crypto";
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
const root = import.meta.dirname;

// 版本号的唯一来源：仓库根目录的 VERSION（第 1 行营销版本 X.Y.Z）。
// index.html 里只写 {{VERSION}} 占位符，不要手写版本号——漏改一处就会出现
// “下载按钮指向旧包、页面却写着新版本”这类静默不一致（见 ../错题本.md）。
const version = readFileSync(join(root, "..", "VERSION"), "utf8").split("\n")[0].trim();
if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error(`VERSION 第 1 行必须是 X.Y.Z，实际是 '${version}'`);

const dist = join(root, "dist");
const rawHtml = readFileSync(join(root, "index.html"), "utf8");
const html = rawHtml.replaceAll("{{VERSION}}", version);
if (html.includes("{{")) throw new Error("index.html 里还有未替换的 {{占位符}}");

for (const required of ["assets/logo.png", "assets/hoot-editor.jpg", "assets/annotation-example.png", "https://github.com/xiezhaoye/Hoot"]) {
  if (!html.includes(required)) throw new Error(`Missing page asset or project link: ${required}`);
}
// 下载按钮必须是 R2 域名 + 当前版本的包名：GitHub 直连在国内不稳定，也只该作为备份。
const download = `https://hoot-dl.xiezhaoye.site/Hoot-${version}-macos-arm64.zip`;
if (!html.includes(download)) throw new Error(`下载链接没有指向 ${download}`);
const strayZip = [...html.matchAll(/https:\/\/([^"'\s]+)\/(Hoot-[^"'\s]+\.zip)/g)].filter(
  (m) => m[1] !== "hoot-dl.xiezhaoye.site" || `Hoot-${version}-macos-arm64.zip` !== m[2],
);
if (strayZip.length) throw new Error(`存在指向错误域名或旧版本的下载链接：${strayZip.map((m) => m[0]).join(", ")}`);

rmSync(dist, { recursive: true, force: true });
mkdirSync(dist, { recursive: true });
for (const file of ["style.css", "site.js", "404.html", "robots.txt", "sitemap.xml", "_headers", "assets"]) {
  cpSync(join(root, file), join(dist, file), { recursive: true });
}

// Content-addressed assets prevent a cached stylesheet or script from outliving its page markup.
let output = html;
for (const file of ["style.css", "site.js"]) {
  const content = readFileSync(join(root, file));
  const hash = createHash("sha256").update(content).digest("hex").slice(0, 12);
  const [name, extension] = file.split(".");
  const versioned = `${name}.${hash}.${extension}`;
  writeFileSync(join(dist, versioned), content);
  output = output.replace(`"${file}"`, `"${versioned}"`);
}
writeFileSync(join(dist, "index.html"), output);
console.log(`Built Hoot landing/dist for v${version}`);
