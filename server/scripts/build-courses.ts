import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

// Builds the course manifest and the server's problem bank from the course folders. Run it after any change under shared/:
//
//   npm run build-courses            write shared/courses/index.json and server/data/problems.json
//   npm run build-courses -- --check fail (exit 1) when either file is stale; CI runs this through the tests
//
// A course is a folder shared/courses/<slug>/ with a problems.json. A new folder needs no code change: it is found, validated
// and listed on the next run. An optional course.json beside it sets the title, group and grade; without one the title and
// group are worked out from the folder name and the problems' level (and the run says so).
//
// The first twelve problems (ids u3-..., BC Math 9 unit 3 equations) live in shared/problems.json and are listed as one more
// course, so older app builds that send those ids keep working.

export type CourseGroup = "elementary" | "high_school" | "college";
export const GROUP_ORDER: CourseGroup[] = ["elementary", "high_school", "college"];

export type CourseEntry = {
  slug: string;
  title: string;
  group: CourseGroup;
  grade: number | null;
  level: string;
  count: number;
  file: string; // path under shared/
};

export type BankProblem = {
  id: string;
  course: string;
  prompt_plain: string;
  worked_solution: string[];
  final_answer: string;
  level: string;
};

export type Built = { manifestText: string; serverBankText: string; courses: CourseEntry[]; problems: BankProblem[]; notes: string[] };

const LEGACY = { slug: "bc-math-9-unit-3", title: "BC Math 9 · Unit 3 equations", group: "high_school", grade: 9, file: "problems.json" } as const;

const SLUG = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const PROBLEM_ID = /^[a-z0-9][a-z0-9-]{0,39}$/;

const WORDS: Record<string, string> = {
  bc: "BC",
  math: "Math",
  fm: "Foundations of Math",
  fmpc: "Foundations of Math and Pre-calculus",
  pc: "Pre-calculus",
  calc: "Calculus",
};

export class CourseBuildError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CourseBuildError";
  }
}

const isText = (v: unknown): v is string => typeof v === "string" && v.trim().length > 0;
const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

function readJson(path: string, where: string): unknown {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (err) {
    throw new CourseBuildError(`${where}: cannot read ${path}: ${(err as Error).message}`);
  }
}

type RawProblem = { id: string; prompt_plain: string; worked_solution: string[]; final_answer: string; level: string };

// Every problem in a file, checked field by field. Returns only what the server needs.
function checkProblems(raw: unknown, where: string): RawProblem[] {
  if (!Array.isArray(raw) || raw.length === 0) throw new CourseBuildError(`${where}: must be a non-empty array`);
  return raw.map((entry, index) => {
    const label = `${where} #${index + 1}${isRecord(entry) && isText(entry.id) ? ` (${entry.id})` : ""}`;
    if (!isRecord(entry)) throw new CourseBuildError(`${label}: not an object`);
    const { id, prompt_plain, prompt_latex, prompt_parts, worked_solution, final_answer, level } = entry;
    if (!isText(id) || !PROBLEM_ID.test(id)) throw new CourseBuildError(`${label}: id must be 1-40 characters of a-z, 0-9 and -`);
    if (!isText(prompt_plain)) throw new CourseBuildError(`${label}: prompt_plain is missing`);
    if (!isText(prompt_latex)) throw new CourseBuildError(`${label}: prompt_latex is missing`);
    if (!isText(final_answer)) throw new CourseBuildError(`${label}: final_answer is missing`);
    if (!isText(level)) throw new CourseBuildError(`${label}: level is missing`);
    if (!Array.isArray(worked_solution) || worked_solution.length === 0 || !worked_solution.every(isText)) {
      throw new CourseBuildError(`${label}: worked_solution must be a non-empty list of non-empty lines`);
    }
    if (!Array.isArray(prompt_parts) || prompt_parts.length === 0) throw new CourseBuildError(`${label}: prompt_parts is missing`);
    for (const part of prompt_parts) {
      const okText = isRecord(part) && typeof part.text === "string";
      const okFrac = isRecord(part) && isRecord(part.frac) && isText(part.frac.num) && isText(part.frac.den);
      if (!okText && !okFrac) throw new CourseBuildError(`${label}: a prompt part has neither text nor frac`);
    }
    return { id, prompt_plain, worked_solution, final_answer, level };
  });
}

function titleFromSlug(slug: string): string {
  return slug
    .split("-")
    .map((word) => WORDS[word] ?? (/^\d+$/.test(word) ? word : word.charAt(0).toUpperCase() + word.slice(1)))
    .join(" ");
}

function gradeFromSlug(slug: string): number | null {
  const match = /-(\d{1,2})$/.exec(slug);
  return match ? Number(match[1]) : null;
}

function groupFor(level: string, grade: number | null): CourseGroup {
  if (level === "college" || level === "advanced") return "college";
  if (grade !== null) return grade <= 7 ? "elementary" : "high_school";
  return level === "elementary" || level === "middle_school" ? "elementary" : "high_school";
}

type Meta = { title?: string; group?: CourseGroup; grade?: number | null; level?: string };

function readMeta(dir: string, slug: string): Meta {
  const path = join(dir, "course.json");
  if (!existsSync(path)) return {};
  const raw = readJson(path, `course ${slug}`);
  if (!isRecord(raw)) throw new CourseBuildError(`course ${slug}: course.json must be an object`);
  const meta: Meta = {};
  if (raw.title !== undefined) {
    if (!isText(raw.title)) throw new CourseBuildError(`course ${slug}: course.json title must be text`);
    meta.title = raw.title;
  }
  if (raw.group !== undefined) {
    if (!GROUP_ORDER.includes(raw.group as CourseGroup)) {
      throw new CourseBuildError(`course ${slug}: course.json group must be one of ${GROUP_ORDER.join(", ")}`);
    }
    meta.group = raw.group as CourseGroup;
  }
  if (raw.grade !== undefined) {
    if (raw.grade !== null && !(Number.isInteger(raw.grade) && (raw.grade as number) >= 1 && (raw.grade as number) <= 12)) {
      throw new CourseBuildError(`course ${slug}: course.json grade must be null or a whole number 1-12`);
    }
    meta.grade = raw.grade as number | null;
  }
  if (raw.level !== undefined) {
    if (!isText(raw.level)) throw new CourseBuildError(`course ${slug}: course.json level must be text`);
    meta.level = raw.level;
  }
  return meta;
}

// Reads every course under `sharedDir` and returns the two files' text, plus a note for each thing worth saying.
export function buildCourses(sharedDir: string): Built {
  const notes: string[] = [];
  const entries: CourseEntry[] = [];
  const problems: BankProblem[] = [];

  const add = (slug: string, meta: Meta, file: string, list: RawProblem[], fromFolder: boolean) => {
    const levels = [...new Set(list.map((p) => p.level))];
    if (levels.length > 1 && !meta.level) {
      throw new CourseBuildError(`course ${slug}: problems mix levels (${levels.join(", ")}); set "level" in course.json`);
    }
    const level = meta.level ?? levels[0]!;
    const grade = meta.grade !== undefined ? meta.grade : gradeFromSlug(slug);
    const group = meta.group ?? groupFor(level, grade);
    let title = meta.title;
    if (!title) {
      title = titleFromSlug(slug);
      if (fromFolder) notes.push(`course ${slug}: no course.json, so the title is "${title}" and the group is ${group}; add one to choose them`);
    }
    entries.push({ slug, title, group, grade, level, count: list.length, file });
    for (const p of list) problems.push({ ...p, course: slug });
  };

  // Course folders.
  const coursesDir = join(sharedDir, "courses");
  const slugs = readdirSync(coursesDir).filter((name) => statSync(join(coursesDir, name)).isDirectory()).sort();
  for (const slug of slugs) {
    if (!SLUG.test(slug)) throw new CourseBuildError(`course folder "${slug}": the name must be lowercase letters, digits and hyphens`);
    const dir = join(coursesDir, slug);
    const file = join(dir, "problems.json");
    if (!existsSync(file)) throw new CourseBuildError(`course ${slug}: ${file} is missing`);
    add(slug, readMeta(dir, slug), `courses/${slug}/problems.json`, checkProblems(readJson(file, `course ${slug}`), `course ${slug}`), true);
  }

  // The original twelve.
  const legacyFile = join(sharedDir, LEGACY.file);
  add(LEGACY.slug, { title: LEGACY.title, group: LEGACY.group, grade: LEGACY.grade }, LEGACY.file,
    checkProblems(readJson(legacyFile, "legacy bank"), "legacy bank"), false);
  if (entries.some((e) => e.slug === LEGACY.slug && slugs.includes(LEGACY.slug))) {
    throw new CourseBuildError(`a course folder named ${LEGACY.slug} clashes with the original bank`);
  }

  // One id means one problem, across every course.
  const seen = new Map<string, string>();
  const clashes: string[] = [];
  for (const p of problems) {
    const first = seen.get(p.id);
    if (first) clashes.push(`${p.id} (${first} and ${p.course})`);
    else seen.set(p.id, p.course);
  }
  if (clashes.length) throw new CourseBuildError(`duplicate problem ids: ${clashes.join(", ")}`);

  const rank = (e: CourseEntry) => GROUP_ORDER.indexOf(e.group);
  entries.sort((a, b) => rank(a) - rank(b) || (a.grade ?? 99) - (b.grade ?? 99) || a.title.localeCompare(b.title) || a.slug.localeCompare(b.slug));

  const manifestText = JSON.stringify({ version: 1, courses: entries }, null, 2) + "\n";
  const courseMeta = entries.map(({ slug, title, group, grade, level }) => ({ slug, title, group, grade, level }));
  const serverBankText =
    `{"courses":${JSON.stringify(courseMeta)},\n"problems":[\n` + problems.map((p) => JSON.stringify(p)).join(",\n") + "\n]}\n";
  return { manifestText, serverBankText, courses: entries, problems, notes };
}

// ---------------------------------------------------------------- command line

const here = (rel: string) => fileURLToPath(new URL(rel, import.meta.url));
const SHARED = here("../../shared");
const MANIFEST_PATH = join(SHARED, "courses", "index.json");
const SERVER_BANK_PATH = here("../data/problems.json");

function main(): number {
  const check = process.argv.includes("--check");
  let built: Built;
  try {
    built = buildCourses(SHARED);
  } catch (err) {
    console.error(`build-courses: FAILED: ${(err as Error).message}`);
    return 1;
  }
  for (const note of built.notes) console.warn(`build-courses: note: ${note}`);
  const summary = `${built.courses.length} courses, ${built.problems.length} problems, server bank ${Buffer.byteLength(built.serverBankText)} bytes`;

  const current = (path: string) => (existsSync(path) ? readFileSync(path, "utf8") : "");
  const stale = [
    current(MANIFEST_PATH) !== built.manifestText ? "shared/courses/index.json" : "",
    current(SERVER_BANK_PATH) !== built.serverBankText ? "server/data/problems.json" : "",
  ].filter(Boolean);

  if (check) {
    if (stale.length) {
      console.error(`build-courses: STALE: ${stale.join(", ")} (run: npm run build-courses in server/)`);
      return 1;
    }
    console.log(`build-courses: up to date: ${summary}`);
    return 0;
  }
  writeFileSync(MANIFEST_PATH, built.manifestText);
  writeFileSync(SERVER_BANK_PATH, built.serverBankText);
  console.log(`build-courses: wrote ${summary}${stale.length ? ` (changed: ${stale.join(", ")})` : " (nothing changed)"}`);
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) process.exit(main());
