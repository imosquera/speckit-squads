#!/usr/bin/env bun
/**
 * Script-path check, run by check-cli-usage.sh from the repo root (paths are
 * cwd-relative). See the numbered rules in check-cli-usage.sh. `.ts` scripts under
 * `scripts/ts/` are checked exactly like `.sh` ones: declared in provides.scripts,
 * resolving on disk.
 */
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { KINDS, cmp, commandFiles, manifests, scriptsBlock } from "./manifest.ts";

const problems: string[] = [];
const declared = new Map<string, Set<string>>();

function isFile(p: string): boolean {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

/** File lines as Python's universal-newline iteration sees them. */
function lines(path: string): string[] {
  const out = readFileSync(path, "utf8").split(/\r\n|\r|\n/);
  if (out.at(-1) === "") out.pop();
  return out;
}

for (const [kind, manifest] of KINDS) {
  for (const { path, id } of manifests("", kind, manifest)) {
    const block = scriptsBlock(readFileSync(path, "utf8"));
    const files = new Set<string>();
    for (const m of block.matchAll(/^\s*file:\s*["']?([^"'\s]+)/gm)) if (m[1]) files.add(m[1]);
    declared.set(`${kind}/${id}`, files);
    for (const f of [...files].sort(cmp)) {
      if (!isFile(join(kind, id, f))) problems.push(`${path}: declared script does not exist: ${f}`);
    }
  }
}

const REF =
  /\.specify\/(extensions|presets)\/([A-Za-z0-9_-]+)\/(scripts\/[A-Za-z0-9_./-]+)|\.specify\/scripts\/(bash|powershell|python)\/([A-Za-z0-9_./-]+)/g;

const cmdFiles = [...commandFiles("extensions"), ...commandFiles("presets")].sort(cmp);
for (const cf of cmdFiles) {
  lines(cf).forEach((line, i) => {
    const lineno = i + 1;
    for (const m of line.matchAll(REF)) {
      const [whole, kind, oid, rel, tree, tail] = m;
      if (kind && oid && rel) {
        const decl = declared.get(`${kind}/${oid}`);
        if (!isFile(join(kind, oid, rel))) {
          problems.push(`${cf}:${lineno}: path does not exist: ${whole}`);
        } else if (!decl) {
          problems.push(`${cf}:${lineno}: unknown ${kind.slice(0, -1)} id '${oid}'`);
        } else if (!decl.has(rel)) {
          problems.push(
            `${cf}:${lineno}: ${rel} is not declared in ${kind}/${oid}/` +
              `${kind === "extensions" ? "extension.yml" : "preset.yml"} ` +
              `(add it under provides.scripts)`,
          );
        }
      } else if (tree && tail && tail.includes("/")) {
        // Core tree: flat by construction. A subdirectory here is the
        // `.specify/scripts/bash/<extension-id>/` mistake.
        problems.push(
          `${cf}:${lineno}: \`.specify/scripts/${tree}/\` is the FLAT core ` +
            `tree — it has no '${tail.split("/")[0]}/' subdirectory. Extension ` +
            `scripts live at .specify/extensions/<id>/scripts/${tree}/`,
        );
      }
    }
  });
}

const BARE_CPD = /\$(?:CLAUDE_PROJECT_DIR\b|\{CLAUDE_PROJECT_DIR\})/;
for (const cf of cmdFiles) {
  let inBash = false;
  lines(cf).forEach((line, i) => {
    const stripped = line.trim();
    if (stripped.startsWith("```")) {
      inBash = !inBash ? stripped.slice(3).trim() === "bash" : false;
      return;
    }
    if (inBash && BARE_CPD.test(line)) {
      problems.push(
        `${cf}:${i + 1}: bare $CLAUDE_PROJECT_DIR in a bash block — it is empty ` +
          `in an interactive session (issue #59). Use ` +
          `PROJECT_DIR="\${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}" ` +
          `in this block and reference $PROJECT_DIR`,
      );
    }
  });
}

for (const p of problems) console.error(p);
if (problems.length > 0) {
  console.error("error: command files reference script paths that do not resolve");
  process.exit(1);
}
let total = 0;
for (const v of declared.values()) total += v.size;
console.log(`script path check: ok (${total} declared scripts, ${cmdFiles.length} command files)`);
