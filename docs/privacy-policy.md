# Pencil Tutor privacy policy

**DRAFT. Not legal advice. Review with a BC privacy lawyer before any family is asked to agree to it.** Version 2026-11-14.1 (the same version as the consent screen). Items marked "to confirm" are things nobody has checked yet.

This is the full version. The short version is the screen you saw before turning memory on. If anything here is unclear, ask Edward and he will explain it in plain words.

## Who this is about

Pencil Tutor is a tutoring app run by Edward Tran, a private tutor in British Columbia. A student uses an iPad with a personal code. The code stands in for a name: the app never asks for a name, email address, school, grade, birthday or location. A code comes one of two ways. Edward can hand one to a student, and then he keeps the list of which code belongs to which student on paper, off the server. Or the student taps "Start free" and the server makes a code on the spot; nobody, including Edward, knows who holds a free code.

*Changed 2026-11-19: added free codes and the network-address limit in Part A. Nothing about tutor memory changed, so the memory agreement version above is unchanged.*

Contact for any privacy question or request: [Edward to fill in a contact email before launch].

## Part A: what happens whether or not memory is on

- **The student's work is looked at, not kept.** While a student works, the app sends a picture of the page to an AI service, together with the problem and the answer key, so the tutor can decide whether to stay quiet or give a hint. The picture is not saved on our server. The student's spoken questions are sent as a short recording to be turned into text, then discarded; we never store recordings.
- **Time is counted.** The server keeps, per code and month: how many seconds of real working time, how many times the tutor looked or was asked something, and how many characters of speech were produced. This is how the monthly hours limit works.
- **Free codes and network addresses.** When a student taps "Start free", the server uses the network (IP) address of that request for one thing: to allow only a few free codes (3) per network in 24 hours, so the free service is not drained by one person. The server stores only a keyed one-way scramble of the address (a keyed hash), never the address itself, and nothing links it to the code that was made, except that both carry the same creation time. The scramble is personal information, so it is kept only as long as it is needed: it is deleted once it has been untouched for 2 days, when the next free code is made or when Edward runs his admin tool (there is no automatic timer, so it can stay longer while no one is asking for free codes). Our hosting service (Vercel) receives the address in order to deliver any request, and may keep it in its own records under its own policy (to confirm). The app cannot tell whether two free codes belong to the same person.
- **A shared budget for free tutoring.** The server keeps one number per month: the estimated cost of the AI services used by all free codes together, plus how many ElevenLabs voice characters they used (a count, not a cost). It holds no per-person data. When the estimate reaches the monthly budget, free tutoring pauses until the 1st and the app says so; codes Edward hands out are not affected. The estimate comes from published prices and the sizes of requests, not from the providers' invoices.
- **The voice is an AI voice.** What the student hears is computer-generated speech, not a person talking live. Today it is a stock voice from a speech service; it may later be a synthetic copy of Edward's own voice, and this page will say so first.
- **Who handles the data on our behalf.** Hosting (Vercel), the database (Neon), the AI that reads pages and writes hints (OpenAI, and Google Gemini if Edward switches to it), and the voice service (ElevenLabs, which receives only the sentence to be spoken). These companies are in the United States or process data there. Region settings are to confirm.
- **Logs.** The server writes a log line for each request with sizes, counts and short reason labels. It never writes pictures, recordings, what the student said, hints, notes, or codes. A student appears in the logs only as a short scrambled id.
- **The iPad's own log.** The app keeps a session log on the iPad (timings, counts, and the short written hint, at most 8 words, shown beside a line). It holds no name. The app has a button that shares this log, which is how Edward looks at how a session went when a family sends it.

## Part B: tutor memory (off unless a parent or guardian agrees)

### What is remembered

Only if memory is on:

- Which problems the student worked on, on what date, how many times the tutor looked, how many times it stepped in, and on which line number.
- How many times the student asked the tutor a question (a count, not the question).
- Short notes Edward writes after a lesson, for example how the student likes to be helped.

Never remembered on our server: names, pictures of the page, recordings, what the student said or wrote, the words of any hint. (The iPad keeps its own session log, see Part A.)

### Why

So the tutor can word its hints in a way that suits this student, and so Edward can see how practice is going. The notes can change **how** the tutor phrases a hint. They never change **when** it speaks up, and the tutor is told never to refer to earlier sessions in a hint. It is not used for advertising, never sold, and never shared with anyone except the services listed below. There are no streaks, points or rewards tied to memory.

### Who sees it

Edward. The AI service that powers the tutor also receives Edward's notes, but only at the moment the tutor is about to speak a hint, in a separate text-only request (no picture of the page) that asks it to word that one hint in a way that suits the student. The notes are never part of the request that decides whether the tutor speaks up. That service is OpenAI, or Google if Edward switches to it. OpenAI says information sent through its API is not used to train its models unless a customer opts in (its data controls page, read 2026-11-14). It has also said it can keep API inputs for up to 30 days for abuse monitoring; that figure came from a community post quoting OpenAI and is to confirm. Google's terms for the paid Gemini service are to confirm. The database holding the memory is Neon in the United States (region to confirm).

### Who can agree

A parent or legal guardian, for a student under 19 (the age of majority in BC). An adult student can agree for themselves. The app asks the person to say which they are; it cannot check. For the strongest record, a parent can instead sign a paper form that Edward keeps and records on the server by date only. No name is stored either way. Agreeing is a choice. The tutor works the same without it.

### How long

Until you erase it. Edward also deletes the memory of any code that has not been used for 12 months. That deletion is something Edward does by hand; it is not an automatic timer. Whether 12 months is the right limit, and whether any law requires keeping some records for a year after they are used to make a decision about a person, is to confirm with a lawyer.

### See it, take it, erase it, change your mind

- **See it:** Settings, then "What the tutor remembers", shows the counts and the recent problems. Edward's notes are not shown on the iPad, because a student should not stumble on a tutor's private observations; they are yours on request.
- **Take a copy:** ask Edward. He can export everything stored about a code. We will answer within 30 days (the BC limit).
- **Erase it:** Settings, then "What the tutor remembers", then "Erase". Or ask Edward. Erasing deletes the practice record and the notes.
- **Change your mind:** turn memory off in the same place, any time. The tutor stops remembering straight away. The app asks whether to erase what is already stored. Turning memory off does not stop the tutor from working.
- **What is kept after an erase:** a small log that says memory was turned on or off, when, and which version of this policy was shown. It holds no names and no content. Ask Edward if you want even that removed.
- **Backups:** Neon keeps a short history of database changes so it can undo mistakes (6 hours on the free plan, per Neon's documentation read 2026-11-14). Erased data can remain in that history for up to that long.
- **If the rules change:** if this policy changes in a way that matters, memory turns off until you are asked again.

### What could go wrong

- A note could be wrong, or put in a way that is unkind. Notes are written as if the student or parent will read them, because they can ask to. A wrong note can change how a hint is worded; it cannot make the tutor interrupt more or less.
- The tutor could say something about the past that never happened. It is told not to, and the server checks for the most common phrasings and, if it finds one, speaks the ordinary hint instead. That check is not perfect.
- The reworded spoken hint could say something slightly different from the ordinary one. The written hint on the page, which the tutor also uses to decide later, is never reworded. Edward reviews samples.
- Withdrawing takes effect on the next request. A request that was already on its way to the AI service at that moment (about two seconds at most) can still carry the notes once.
- The database could be leaked. It would show which problems a code practised, on which dates, and any notes. It holds no names. The list of who a code belongs to is not on the server.
- An AI service could handle information differently from what its documents promise.

### Children

Parents and guardians, not children, decide whether memory is on. The Office of the Privacy Commissioner of Canada's position is that consent should come from a parent or guardian for anyone under 13 in all but exceptional cases; this app asks for a parent or guardian for everyone under 19 and for the adult student only if they are an adult. A checkbox on a device a child may be holding is weak evidence of who tapped it; that limit is why the signed-form route exists.

### Your rights and how to complain

Under BC's Personal Information Protection Act you can ask what is held about you, ask for corrections, and withdraw consent. If you are not satisfied, you can complain to the Office of the Information and Privacy Commissioner for British Columbia, or to the Office of the Privacy Commissioner of Canada.

### Questions still open

For a lawyer, listed so nothing is hidden: whether a checkbox is enough for a parent's agreement on a child's device; whether adaptive tutoring counts as using information to make a decision about a person (BC PIPA section 35(1) can require keeping such information for a year); whether storing information in the United States needs more than the notice given here; whether a privacy impact assessment is expected before launch (the Office of the Privacy Commissioner's draft Children's Privacy Code, released 2026-10-20, is non-binding and open for comment until 2027-01-20); and the retention period.
