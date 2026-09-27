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

// ---- iOS / web preset selection (install.ts) --------------------------------
// A preset `X-ios` whose base `X` exists wraps the same command as `X`, so a
// project gets exactly one of the pair. Derived from names; no hand-kept list.

export const IOS_SUFFIX = "-ios";

/** Directories never searched for an Xcode/SwiftPM marker. */
const DETECT_SKIP = new Set(["Pods", "Carthage", "DerivedData", "node_modules"]);

const isIosMarker = (name: string): boolean =>
  name === "Package.swift" || name.endsWith(".xcodeproj") || name.endsWith(".xcworkspace");

/**
 * An iOS project has a *.xcodeproj, *.xcworkspace or Package.swift at `dir`'s root
 * or one level down. Dotted directory names (hidden dirs like .build/.git, and
 * bundles like Foo.app/Foo.xcassets) are not descended into. Returns the first
 * marker found (relative to `dir`), or null.
 */
export function detectIos(dir: string): string | null {
  const list = (d: string): string[] => {
    try {
      return readdirSync(d).sort(cmp);
    } catch {
      return [];
    }
  };
  const top = list(dir);
  const hit = top.find(isIosMarker);
  if (hit) return hit;
  for (const sub of top) {
    if (sub.includes(".") || DETECT_SKIP.has(sub)) continue;
    const inner = list(join(dir, sub)).find(isIosMarker);
    if (inner) return `${sub}/${inner}`;
  }
  return null;
}

/** `X` for `X-ios`, else null. */
export const iosBase = (id: string): string | null =>
  id.endsWith(IOS_SUFFIX) && id.length > IOS_SUFFIX.length ? id.slice(0, -IOS_SUFFIX.length) : null;

/**
 * Which presets to install for a mode. For each `X-ios` whose base `X` is in `ids`,
 * iOS mode keeps `X-ios` and skips `X`; web mode the reverse. An `X-ios` with no base
 * is iOS-only. `counterpart` maps each installed id to the skipped member of its pair
 * (what --force removes when switching modes). Order of `ids` is preserved.
 */
export function selectPresets(
  ids: readonly string[],
  ios: boolean,
): { install: string[]; skip: string[]; counterpart: Record<string, string> } {
  const all = new Set(ids);
  const skip = new Set<string>();
  const counterpart: Record<string, string> = {};
  for (const id of ids) {
    const base = iosBase(id);
    if (base === null) continue;
    if (!all.has(base)) {
      if (!ios) skip.add(id);
      continue;
    }
    const [keep, drop] = ios ? [id, base] : [base, id];
    skip.add(drop);
    counterpart[keep] = drop;
  }
  return { install: ids.filter((id) => !skip.has(id)), skip: ids.filter((id) => skip.has(id)), counterpart };
}

/** A preset's priority: its own entry, else its base's (for `X-ios`), else `dflt`. */
export function presetPriority(priorities: Readonly<Record<string, number>>, id: string, dflt = 10): number {
  const base = iosBase(id);
  return priorities[id] ?? (base === null ? undefined : priorities[base]) ?? dflt;
}
