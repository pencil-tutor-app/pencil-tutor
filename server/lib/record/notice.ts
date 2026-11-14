import { createHash } from "node:crypto";

// The consent text. The server owns it and the app shows exactly what the server returns, so the version stored with a consent
// always names the words the person saw. Change a word and you must change NOTICE_VERSION: test/record.test.ts pins the hash of
// this text to the version, and a new version means everyone is asked again (memory stays off until they agree to the new one).
// Written to be read in about a minute; the full policy is one tap away (docs/privacy-policy.md, served at /api/privacy).
// DRAFT: not legal advice; to be reviewed with a BC privacy lawyer before any family is asked.

export const NOTICE_VERSION = "2026-11-14.1";

export type NoticeSection = { heading: string; body: string };

export const NOTICE: { title: string; intro: string; sections: NoticeSection[] } = {
  title: "Let the tutor remember?",
  intro: "Memory is optional. If you leave it off, the tutor works exactly the same. A parent or guardian decides for a student, or an adult student decides for themselves.",
  sections: [
    {
      heading: "What is remembered",
      body: "Which problems were worked on and when, how many times the tutor looked and stepped in (and on which line), how many questions were asked, and short notes Edward writes after a lesson. Not remembered: names, pictures of the page, recordings, or anything the student says or writes.",
    },
    {
      heading: "Why",
      body: "So the tutor's hints can be worded in a way that suits the student. It never changes when the tutor speaks up. It is not used for ads, never sold, and not shared except with the services that run the tutor.",
    },
    {
      heading: "Who sees it",
      body: "Edward. To word a hint, an AI service (OpenAI, in the United States) may also see Edward's notes for that one hint. The records are kept in a database service (Neon).",
    },
    {
      heading: "How long",
      body: "Until you erase it. Edward also deletes the memory of any code that has not been used for 12 months, by hand.",
    },
    {
      heading: "See it, take it, erase it",
      body: "In Settings, \"What the tutor remembers\" shows what is stored and lets you turn memory off or erase it, at any time. Ask Edward for a copy of everything, including his notes.",
    },
    {
      heading: "The voice is an AI",
      body: "The tutor you hear is a computer-generated voice, not a person talking to you live.",
    },
  ],
};

export const noticeHash = (): string => createHash("sha256").update(JSON.stringify(NOTICE)).digest("hex");

export const POLICY_PATH = "/api/privacy";
