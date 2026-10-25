import { cpSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
const root = import.meta.dirname;
const dist = join(root, "dist");
const html = readFileSync(join(root, "index.html"), "utf8");
for (const required of ["assets/logo.png", "assets/hoot-editor.jpg", "assets/annotation-example.png", "https://github.com/xiezhaoye/Hoot"]) {
  if (!html.includes(required)) throw new Error(`Missing page asset or project link: ${required}`);
}
rmSync(dist, { recursive: true, force: true });
mkdirSync(dist, { recursive: true });
for (const file of ["index.html", "style.css", "site.js", "404.html", "robots.txt", "sitemap.xml", "_headers", "assets"]) {
  cpSync(join(root, file), join(dist, file), { recursive: true });
}
console.log("Built Hoot landing/dist");
