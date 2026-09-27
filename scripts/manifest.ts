import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";

// Shared manifest parsing for the repo-root tooling. Deliberately a regex reader,
// not a YAML parser: it only needs `provides.scripts[]` and must stay stdlib-only.

/** The body of `provides:` -> `scripts:` in a manifest, or "" when absent. */
export function scriptsBlock(text: string): string {
  const m = /^provides:[ \t]*$\n([\s\S]*?)(?=^\S)/m.exec(text + "\n\x00");
  if (!m) return "";
  const s = /^ {2}scripts:[ \t]*$\n([\s\S]*?)(?=^ {2}\S|(?![\s\S]))/m.exec(m[1] ?? "");
  return s ? (s[1] ?? "") : "";
}

export const KINDS = [
  ["extensions", "extension.yml"],
  ["presets", "preset.yml"],
] as const;

/** Python-style codepoint comparison, for `sorted()`-equivalent ordering. */
export function cmp(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/**
 * Equivalent of `sorted(glob(join(base, kind, "*", manifest)))`: every existing
 * `<base>/<kind>/<id>/<manifest>`, hidden ids skipped, sorted by full path.
 */
export function manifests(base: string, kind: string, manifest: string): { path: string; id: string }[] {
  const dir = base === "" ? kind : join(base, kind);
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    return [];
  }
  return names
    .filter((id) => !id.startsWith("."))
    .map((id) => ({ path: base === "" ? `${kind}/${id}/${manifest}` : join(base, kind, id, manifest), id }))
    .filter((e) => existsSync(e.path))
    .sort((a, b) => cmp(a.path, b.path));
}

// Equivalent of glob("<kind>/*/commands/*.md"), unsorted, hidden entries skipped.
export function commandFiles(kind: string): string[] {
  const out: string[] = [];
  for (const { path } of manifests("", kind, "commands")) {
    let names: string[];
    try {
      names = readdirSync(path);
    } catch {
      continue;
    }
    for (const n of names) if (!n.startsWith(".") && n.endsWith(".md")) out.push(`${path}/${n}`);
  }
  return out;
}

// ---- stack-based preset selection (install.ts) -------------------------------
// A preset `X-ios` pairs with a base `X` that wraps the same command: the base is
// the TypeScript/web member, `X-ios` the Swift one. Paired presets are the only
// language-specific ones. The user picks: "none" (no flag) installs neither member
// of any pair, "ts" (--ts) the bases, "ios" (--ios) the -ios members, and "both"
// (--ts --ios, a mixed project such as an Xcode app with a TypeScript backend)
// every preset. Pairs are derived from names; no hand-kept list.

export const IOS_SUFFIX = "-ios";

export type Stack = "none" | "ts" | "ios" | "both";

/** `X` for `X-ios`, else null. */
export const iosBase = (id: string): string | null =>
  id.endsWith(IOS_SUFFIX) && id.length > IOS_SUFFIX.length ? id.slice(0, -IOS_SUFFIX.length) : null;

/**
 * Which presets to install for a stack. For each `X-ios` whose base `X` is in `ids`,
 * "ios" keeps `X-ios` and skips `X`; "ts" the reverse; "none" skips both; "both"
 * keeps both. An `X-ios` with no base is iOS-only. `counterpart` maps each installed
 * id to the skipped member of its pair (what --force removes when switching between
 * ts and ios); "none" and "both" have none, so they never remove anything. Order of
 * `ids` is preserved.
 */
export function selectPresets(
  ids: readonly string[],
  stack: Stack,
): { install: string[]; skip: string[]; counterpart: Record<string, string> } {
  const all = new Set(ids);
  const bases = new Set(ids.map(iosBase).filter((b): b is string => b !== null && all.has(b)));
  const skip = new Set<string>();
  const counterpart: Record<string, string> = {};
  for (const id of ids) {
    const base = iosBase(id);
    const languageSpecific = base !== null || bases.has(id);
    if (!languageSpecific) continue;
    const isIos = base !== null;
    const wanted = stack === "both" || (stack === "ios" && isIos) || (stack === "ts" && !isIos);
    if (!wanted) { skip.add(id); continue; }
    const twin = isIos ? (all.has(base) ? base : null) : `${id}${IOS_SUFFIX}`;
    if ((stack === "ts" || stack === "ios") && twin !== null) counterpart[id] = twin;
  }
  return { install: ids.filter((id) => !skip.has(id)), skip: ids.filter((id) => skip.has(id)), counterpart };
}

/** A preset's priority: its own entry, else its base's (for `X-ios`), else `dflt`. */
export function presetPriority(priorities: Readonly<Record<string, number>>, id: string, dflt = 10): number {
  const base = iosBase(id);
  return priorities[id] ?? (base === null ? undefined : priorities[base]) ?? dflt;
}
