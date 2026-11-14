import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, it } from "node:test";
import { buildCourses, CourseBuildError } from "../scripts/build-courses.js";
import { handleAsk } from "../lib/ask.js";
import { handleWatch } from "../lib/watch.js";
import { buildAskPrompt, buildLiveInstructions, buildWatchPrompt } from "../lib/policy.js";
import { courseCount, courseOf, findProblem, levelFor, levelOf, problemCount, tierOf } from "../lib/problems.js";
import { askBody, captureLogs, deps, fakeModels, liveEnv, post, reply, watchBody } from "./helpers.js";

const here = (rel: string) => fileURLToPath(new URL(rel, import.meta.url));
const SHARED = here("../../shared");

let logs: ReturnType<typeof captureLogs>;
beforeEach(() => {
  logs = captureLogs();
});
afterEach(() => logs.restore());

// A problem that passes every check; tests change one field at a time.
const problem = (id: string, extra: Record<string, unknown> = {}) => ({
  id,
  source: "test",
  prompt_latex: "1 + 1",
  prompt_plain: "1 + 1",
  prompt_parts: [{ text: "1 + 1" }],
  worked_solution: ["1 + 1 = 2"],
  final_answer: "2",
  level: "high_school",
  ...extra,
});

// A throwaway copy of the layout: shared/problems.json plus shared/courses/<slug>/problems.json.
function sandbox(courses: Record<string, unknown[]>, meta: Record<string, unknown> = {}) {
  const dir = mkdtempSync(join(tmpdir(), "courses-"));
  mkdirSync(join(dir, "courses"));
  writeFileSync(join(dir, "problems.json"), JSON.stringify([problem("u3-01")]));
  for (const [slug, list] of Object.entries(courses)) {
    mkdirSync(join(dir, "courses", slug));
    writeFileSync(join(dir, "courses", slug, "problems.json"), JSON.stringify(list));
    if (meta[slug]) writeFileSync(join(dir, "courses", slug, "course.json"), JSON.stringify(meta[slug]));
  }
  return dir;
}

describe("course build: the committed files", () => {
  it("shared/courses/index.json and server/data/problems.json are up to date with the course folders", () => {
    const built = buildCourses(SHARED);
    assert.equal(readFileSync(join(SHARED, "courses", "index.json"), "utf8"), built.manifestText, "run `npm run build-courses` in server/");
    assert.equal(readFileSync(here("../data/problems.json"), "utf8"), built.serverBankText, "run `npm run build-courses` in server/");
  });

  it("lists every folder under shared/courses, with the original 12 as one more course", () => {
    const folders = readdirSync(join(SHARED, "courses")).filter((n) => statSync(join(SHARED, "courses", n)).isDirectory());
    const slugs = buildCourses(SHARED).courses.map((c) => c.slug);
    for (const folder of folders) assert.ok(slugs.includes(folder), `${folder} is missing from the manifest`);
    assert.equal(slugs.length, folders.length + 1);
    assert.ok(slugs.includes("bc-math-9-unit-3"));
  });

  it("counts match the files, every id is unique across courses, and the server bank has every problem", () => {
    const built = buildCourses(SHARED);
    assert.equal(built.courses.reduce((n, c) => n + c.count, 0), built.problems.length);
    assert.equal(new Set(built.problems.map((p) => p.id)).size, built.problems.length);
    assert.equal(problemCount, built.problems.length);
    assert.equal(courseCount, built.courses.length);
  });

  it("keeps the server bank a reasonable size for a Vercel function (under 1.5 MB with room for the later courses)", () => {
    assert.ok(statSync(here("../data/problems.json")).size < 1_500_000);
  });
});

describe("course build: a new folder needs no code change", () => {
  it("picks up a new folder, works out its title, group and grade from the name, and says so", () => {
    const dir = sandbox({ "bc-fmpc-10": [problem("f10-01"), problem("f10-02")] });
    try {
      const built = buildCourses(dir);
      const entry = built.courses.find((c) => c.slug === "bc-fmpc-10")!;
      assert.deepEqual(
        [entry.title, entry.group, entry.grade, entry.count, entry.file],
        ["BC Foundations of Math and Pre-calculus 10", "high_school", 10, 2, "courses/bc-fmpc-10/problems.json"],
      );
      assert.ok(built.notes.some((n) => n.includes("bc-fmpc-10") && n.includes("no course.json")));
      assert.deepEqual(built.problems.map((p) => [p.id, p.course]), [["f10-01", "bc-fmpc-10"], ["f10-02", "bc-fmpc-10"], ["u3-01", "bc-math-9-unit-3"]]);
    } finally {
      rmSync(dir, { recursive: true });
    }
  });

  it("course.json sets the title, group and grade, and college levels group as college", () => {
    const dir = sandbox(
      { "bc-calc-12": [problem("k12-01", { level: "college" })], "stats-1": [problem("s1-01", { level: "college" })] },
      { "bc-calc-12": { title: "Calculus 12", group: "high_school", grade: 12 } },
    );
    try {
      const { courses, notes } = buildCourses(dir);
      assert.deepEqual(courses.find((c) => c.slug === "bc-calc-12"), {
        slug: "bc-calc-12", title: "Calculus 12", group: "high_school", grade: 12, level: "college", tier: "standard", count: 1, file: "courses/bc-calc-12/problems.json",
      });
      assert.equal(courses.find((c) => c.slug === "stats-1")!.group, "college");
      assert.ok(!notes.some((n) => n.includes("bc-calc-12")));
    } finally {
      rmSync(dir, { recursive: true });
    }
  });

  it("orders elementary, then high school, then college, by grade", () => {
    const dir = sandbox({
      "bc-math-12": [problem("a-1")], "bc-math-5": [problem("b-1")], "calc-1": [problem("c-1", { level: "college" })], "bc-math-8": [problem("d-1")],
    });
    try {
      assert.deepEqual(buildCourses(dir).courses.map((c) => c.slug), ["bc-math-5", "bc-math-8", "bc-math-9-unit-3", "bc-math-12", "calc-1"]);
    } finally {
      rmSync(dir, { recursive: true });
    }
  });
});

describe("course build: bad input fails loudly", () => {
  const fails = (courses: Record<string, unknown[]>, pattern: RegExp, meta: Record<string, unknown> = {}) => {
    const dir = sandbox(courses, meta);
    try {
      assert.throws(() => buildCourses(dir), (err: unknown) => err instanceof CourseBuildError && pattern.test(err.message));
    } finally {
      rmSync(dir, { recursive: true });
    }
  };

  it("duplicate ids across courses, naming both courses", () => {
    fails({ "bc-math-5": [problem("x-01")], "bc-math-6": [problem("x-01")] }, /duplicate problem ids: x-01 \(bc-math-5 and bc-math-6\)/);
  });

  it("an id that clashes with the original 12", () => {
    fails({ "bc-math-5": [problem("u3-01")] }, /duplicate problem ids: u3-01 \(bc-math-9-unit-3 and bc-math-5\)|duplicate problem ids: u3-01 \(bc-math-5 and bc-math-9-unit-3\)/);
  });

  it("duplicate ids inside one course", () => {
    fails({ "bc-math-5": [problem("x-01"), problem("x-01")] }, /duplicate problem ids: x-01/);
  });

  it("a missing field, an empty list, a bad part, a bad id and a missing problems.json", () => {
    fails({ "bc-math-5": [problem("x-01", { final_answer: "" })] }, /final_answer is missing/);
    fails({ "bc-math-5": [problem("x-01", { worked_solution: [] })] }, /worked_solution must be a non-empty list/);
    fails({ "bc-math-5": [problem("x-01", { prompt_parts: [{ bogus: 1 }] })] }, /neither text nor frac/);
    fails({ "bc-math-5": [problem("Bad Id")] }, /id must be 1-40 characters/);
    fails({ "bc-math-5": [] }, /must be a non-empty array/);
  });

  it("mixed levels without a course.json level, and a bad course.json", () => {
    fails({ "bc-math-5": [problem("x-01"), problem("x-02", { level: "college" })] }, /mix levels/);
    fails({ "bc-math-5": [problem("x-01")] }, /group must be one of/, { "bc-math-5": { group: "kindergarten" } });
    fails({ "bc-math-5": [problem("x-01")] }, /grade must be null or a whole number/, { "bc-math-5": { grade: 99 } });
  });
});

describe("lookup", () => {
  it("finds the original 12 and a problem from every course by id", () => {
    for (const id of ["u3-01", "u3-04", "m5-01", "m6-01", "m7-01", "m8-01", "m9-01", "c1-01", "la-01", "dm-01"]) {
      assert.ok(findProblem(id), `${id} should be in the bank`);
    }
    assert.equal(findProblem("nope-01"), undefined);
    assert.equal(courseOf(findProblem("u3-04")!)!.slug, "bc-math-9-unit-3");
    assert.equal(courseOf(findProblem("m5-01")!)!.title, "BC Math 5");
    assert.equal(courseOf(findProblem("la-01")!)!.title, "Linear Algebra");
  });

  it("every course runs on the standard (cheap) tier by default, college courses included", () => {
    for (const id of ["c1-01", "la-01", "dm-01", "m5-01", "m7-01", "m8-01", "m9-01", "u3-01", "fm11-33"]) {
      assert.equal(levelOf(findProblem(id)!), "high_school", id);
      assert.equal(tierOf(findProblem(id)!), "standard", id);
    }
    assert.ok(buildCourses(SHARED).courses.every((c) => c.tier === "standard"), "no committed course escalates");
  });

  it("a course tier of advanced (course.json) or a problem level of advanced picks the frontier model; a college level alone does not", () => {
    const p = findProblem("c1-01")!;
    const course = courseOf(p)!;
    assert.equal(levelFor(p, course), "high_school");
    assert.equal(levelFor(p, { ...course, tier: "advanced" }), "advanced");
    assert.equal(levelFor({ ...p, level: "advanced" }, course), "advanced");
    assert.equal(levelFor({ ...p, level: "college" }, course), "high_school");
  });

  it("course.json tier is carried into the manifest and the server bank, and a bad tier fails the build", () => {
    const dir = sandbox({ "k-1": [problem("k-01")], "k-2": [problem("k-02")] }, { "k-1": { tier: "advanced" } });
    try {
      const built = buildCourses(dir);
      assert.deepEqual(built.courses.filter((c) => c.slug.startsWith("k-")).map((c) => [c.slug, c.tier]), [["k-1", "advanced"], ["k-2", "standard"]]);
      assert.ok(built.serverBankText.includes('"slug":"k-1"') && built.serverBankText.includes('"tier":"advanced"'));
    } finally {
      rmSync(dir, { recursive: true });
    }
    const bad = sandbox({ "k-1": [problem("k-01")] }, { "k-1": { tier: "premium" } });
    try {
      assert.throws(() => buildCourses(bad), /tier must be "standard" or "advanced"/);
    } finally {
      rmSync(bad, { recursive: true });
    }
  });
});

describe("the course and level reach the tutor prompts", () => {
  const prompt = (id: string) => buildWatchPrompt({ problem: findProblem(id)!, lines: [], history: [] });

  it("grade 5: a Grade 5 student, simple words", () => {
    const text = prompt("m5-01");
    assert.match(text, /Course: BC Math 5\. The student is a Grade 5 student in British Columbia, about 10 or 11 years old/);
    assert.match(text, /short sentences and simple everyday words/);
    assert.ok(!/college/i.test(text));
  });

  it("calculus: a first-year college student, standard terms, no school-grade wording", () => {
    const text = prompt("c1-01");
    assert.match(text, /Course: Calculus I\. The student is a first-year college or university student/);
    assert.match(text, /standard terms of Calculus I/);
    assert.ok(!/Grade \d/.test(text.split("The problem the student")[0]!));
  });

  it("grade 9 keeps the BC Math 9 vocabulary; grade 8 names its own course", () => {
    assert.match(prompt("m9-01"), /Use BC Math 9 words when they help: variable, term/);
    assert.match(prompt("u3-01"), /Course: BC Math 9 · Unit 3 equations\. The student is a Grade 9 student/);
    assert.match(prompt("m8-01"), /Grade 8 student in British Columbia\. .*Use the words of BC Math 8/);
  });

  it("ask and live prompts carry the same level", () => {
    assert.match(buildAskPrompt({ problem: findProblem("m5-01")!, transcript: "help" }), /Grade 5 student/);
    const live5 = buildLiveInstructions(findProblem("m5-01")!);
    assert.match(live5, /sitting beside a Grade 5 student in British Columbia, about 10 or 11 years old while they work a problem/);
    assert.match(live5, /simple everyday words/);
    assert.ok(!live5.includes("BC Math 9 words"));
    const liveCalc = buildLiveInstructions(findProblem("c1-01")!);
    assert.match(liveCalc, /sitting beside a first-year college or university student while they work a problem/);
    assert.ok(!liveCalc.includes("Grade 9"));
    assert.match(buildLiveInstructions(findProblem("u3-01")!), /Grade 9 student in British Columbia while they work a problem/);
  });

  it("a problem with no course gets no course line and the original BC Math 9 tutor", () => {
    const bare = { id: "x", prompt_plain: "1 + 1", worked_solution: ["2"], final_answer: "2" };
    assert.ok(!buildWatchPrompt({ problem: bare, lines: [], history: [] }).includes("Course:"));
    assert.match(buildLiveInstructions(bare), /Grade 9 student in British Columbia/);
  });

  it("a real watch and ask request sends the course to the model and logs the course label only", async () => {
    const { models, prompts } = fakeModels('{"action":"wait","line":null,"reason":"fine","hint_spoken":null,"hint_written":null}');
    const w = await reply(await handleWatch(post("/api/watch", watchBody({ problem_id: "m5-01" })), deps(liveEnv(), models)));
    assert.equal(w.status, 200);
    assert.match(prompts[0]!, /Course: BC Math 5\. The student is a Grade 5 student/);
    const watchLog = logs.lines.find((l) => l.endpoint === "watch")!;
    assert.equal(watchLog.course, "bc-math-5");
    assert.equal(watchLog.level, "high_school");

    const calc = fakeModels('{"action":"wait","line":null,"reason":"fine","hint_spoken":null,"hint_written":null}');
    await handleWatch(post("/api/watch", watchBody({ problem_id: "c1-01" })), deps(liveEnv(), calc.models));
    assert.match(calc.prompts[0]!, /Course: Calculus I/);
    const calcLog = logs.lines.filter((l) => l.endpoint === "watch").at(-1)!;
    assert.deepEqual([calcLog.course, calcLog.level, calcLog.tier], ["calculus-1", "high_school", "standard"]);
    assert.equal(calcLog.model, "gpt-6-luna", "a college course runs on the cheap model by default");
    assert.equal(watchLog.tier, "standard");

    const asked = fakeModels("Try the first step.");
    const a = await reply(await handleAsk(post("/api/ask", askBody({ problem_id: "la-01" })), deps(liveEnv(), asked.models)));
    assert.equal(a.status, 200);
    assert.match(asked.prompts[0]!, /Course: Linear Algebra/);
    assert.ok(!logs.raw.join("\n").includes("first step"));
  });

  it("an unknown problem id is still a 422", async () => {
    const r = await reply(await handleWatch(post("/api/watch", watchBody({ problem_id: "zz-99" })), deps(liveEnv(), fakeModels("x").models)));
    assert.deepEqual([r.status, r.json.error], [422, "unknown_problem"]);
  });
});
