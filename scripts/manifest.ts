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
// A preset `X-ios` pairs with a base `X` that wraps the same command. The user
// picks the stack: "ts" installs only the base of each pair, "ios" only the -ios
// member, and "both" (a mixed project, e.g. an Xcode app plus a TypeScript
// backend) installs every preset. install.ts maps its flags onto this: --ts is
// ts, --ios is ios, both flags together are both. detectStack() only suggests a
// default. Pairs are derived from names; no hand-kept list.

export const IOS_SUFFIX = "-ios";

export type Stack = "ts" | "ios" | "both";
export const STACKS: readonly Stack[] = ["ts", "ios", "both"];

/** `s` if it is exactly one of STACKS, else null. */
export function parseStack(s: string): Stack | null {
  return (STACKS as readonly string[]).includes(s) ? (s as Stack) : null;
}

/** Directories never searched for an Xcode/SwiftPM marker. */
const DETECT_SKIP = new Set(["Pods", "Carthage", "DerivedData", "node_modules"]);

const isIosMarker = (name: string): boolean =>
  name === "Package.swift" || name.endsWith(".xcodeproj") || name.endsWith(".xcworkspace");

/** Sorted directory entries, or [] when unreadable. */
const listDir = (d: string): string[] => {
  try {
    return readdirSync(d).sort(cmp);
  } catch {
    return [];
  }
};

/** First entry matching `isMarker` at `dir`'s root, else one level down (skipping dotted dirs and DETECT_SKIP). */
function findMarker(dir: string, isMarker: (name: string) => boolean): string | null {
  const top = listDir(dir);
  const hit = top.find(isMarker);
  if (hit) return hit;
  for (const sub of top) {
    if (sub.includes(".") || DETECT_SKIP.has(sub)) continue;
    const inner = listDir(join(dir, sub)).find(isMarker);
    if (inner) return `${sub}/${inner}`;
  }
  return null;
}

/**
 * An iOS project has a *.xcodeproj, *.xcworkspace or Package.swift at `dir`'s root
 * or one level down. Dotted directory names (hidden dirs like .build/.git, and
 * bundles like Foo.app/Foo.xcassets) are not descended into. Returns the first
 * marker found (relative to `dir`), or null.
 */
export function detectIos(dir: string): string | null {
  return findMarker(dir, isIosMarker);
}

const isWebMarker = (name: string): boolean => name === "package.json" || name === "tsconfig.json";

/**
 * A web/TypeScript project has a package.json or tsconfig.json at `dir`'s root or
 * one level down (same skip rules as detectIos: dotted dirs, DETECT_SKIP). Returns
 * the first marker found (relative to `dir`), or null.
 */
export function detectWeb(dir: string): string | null {
  return findMarker(dir, isWebMarker);
}

/**
 * Suggested stack: both markers → "both", only iOS → "ios", else "ts" (the
 * default when nothing is found). `markers` lists what was found, iOS first.
 */
export function detectStack(dir: string): { stack: Stack; markers: string[] } {
  const ios = detectIos(dir);
  const web = detectWeb(dir);
  const markers = [ios, web].filter((m): m is string => m !== null);
  return { stack: ios && web ? "both" : ios ? "ios" : "ts", markers };
}

/** `X` for `X-ios`, else null. */
export const iosBase = (id: string): string | null =>
  id.endsWith(IOS_SUFFIX) && id.length > IOS_SUFFIX.length ? id.slice(0, -IOS_SUFFIX.length) : null;

/**
 * Which presets to install for a stack. For each `X-ios` whose base `X` is in `ids`,
 * "ios" keeps `X-ios` and skips `X`; "ts" the reverse. An `X-ios` with no base is
 * iOS-only. "both" installs every id (skip [], counterpart {}). `counterpart` maps
 * each installed id to the skipped member of its pair (what --force removes when
 * switching stacks). Order of `ids` is preserved.
 */
export function selectPresets(
  ids: readonly string[],
  stack: Stack,
): { install: string[]; skip: string[]; counterpart: Record<string, string> } {
  if (stack === "both") return { install: [...ids], skip: [], counterpart: {} };
  const ios = stack === "ios";
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
