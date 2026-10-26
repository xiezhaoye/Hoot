import { createHash } from "node:crypto";
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
const root = import.meta.dirname;
const dist = join(root, "dist");
const html = readFileSync(join(root, "index.html"), "utf8");
for (const required of ["assets/logo.png", "assets/hoot-editor-0.2.1.jpg", "assets/annotation-example.png", "https://github.com/xiezhaoye/Hoot"]) {
  if (!html.includes(required)) throw new Error(`Missing page asset or project link: ${required}`);
}
rmSync(dist, { recursive: true, force: true });
mkdirSync(dist, { recursive: true });
for (const file of ["index.html", "style.css", "site.js", "404.html", "robots.txt", "sitemap.xml", "_headers", "assets"]) {
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
console.log("Built Hoot landing/dist");
