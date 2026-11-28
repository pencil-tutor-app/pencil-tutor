# Show me how: real-model passes on the hard cases, the planted errors and the routing (2026-11-28)

Scope: decision 4 of `docs/show-me-plan.md` (Revision 3), then widened when the budget ceiling was raised to US$20 (a ceiling, not a target: every run below answers a stated question, a case stopped being repeated once two runs agreed, and the running total is in the last table). Four passes, 100 recorded runs, **US$0.523 in total** (242 provider calls). Script: `server/eval/run-show-me-eval.ts` (`--set core|wide|diagnose`). Metrics rows (labels, counts, tokens, cost, no text): `server/eval/results/show-me-2026-11-28.jsonl` (pass 1), `show-me-wide-2026-11-28.jsonl` (pass 2), `show-me-diagnose-2026-11-28.jsonl` and `show-me-rerun-2026-11-28.jsonl` (pass 3).

## What this found

1. **A real defect: the 80-character answer limit broke every multi-part answer.** Pass 2 rejected null-space, dependence-relation and rank-and-bases problems 6 of 6 times (one more timed out). The diagnosis (pass 2b) shows the writer's answer and the blind solver's answer were the same basis, but the writer's `final_answer` stopped mid-sentence at the 80-character schema limit, so the comparer called it a disagreement. Fix: `LIMITS.solveAnswer = 200` for solve (practice keeps 80), and the prompt asks for a complete answer. Pass 3: la-29 2 of 2 accepted, la-26 2 of 2, la-28 2 of 3.
2. **A real defect: an ill-posed problem was "solved" with a request for input.** For a typed "Solve for x." the writer answered "Please send the equation or a photo of the full problem...", the blind solver said the same, the comparer called them equivalent, and the check accepted: the panel would have shown a request as a solution. Fix: the solve prompt tells the writer to return no steps and an empty answer when the statement lacks what is needed; the handler then says not_checked without paying for a check. Pass 3: 2 of 2 not_checked, US$0.0012 each. "Find x if 2x = y" is answered x = y/2 (correct) and accepted, as it should be.
3. **The check rejected all 14 hand-planted wrong solutions** (2 runs each, 7 kinds): a wrong last step and answer, a wrong row operation with the right final answer (caught by `first_wrong_step`, not by the answers), an inconsistent system claimed to have one solution, a free-variable sign slip, a dropped minus sign in a calculus value, the extraneous log root kept, a modular residue slip. It also accepted 4 of 4 runs of two of my correct hand-written controls (la-02 and pc12-37) and rejected my third control (dm-41's CRT, 2 of 2, `wrong step 4`): that control jumps from k ≡ 3 (mod 7) to "x = 3 + 15" without saying k = 3, so it is a strict reading of hand-written steps, not evidence about the model's own solutions (its own dm-36 solutions were accepted 2 of 2). Planted input is hand-built: this shows the check can catch these slips, not how often a real generator makes them.
4. **Known limit, not fixed: proofs and some multi-part answers are unstable.** The induction proof dm-41 was accepted 1 of 5 real runs (the comparer disagrees about what a proof's "final answer" is); la-28 2 of 3 after the fix and la-20 5 of 6 (the one flip was `equivalent: false` on identical answers "z = 1"). The failure direction is the safe one: the panel says "I couldn't work this one out with confidence" and offers Try again; nothing unchecked is ever shown. A student who types a proof will often see that message. A product call (a looser comparer for proofs, or no check and a label), not made here.
5. **Nothing accepted had a wrong answer.** Of 57 real solve runs, 42 were accepted: 36 give the bank's final answer, 4 give the correct x = y/2 for the typed "Find x if 2x = y" (no bank answer), and 2 were the "Solve for x." requests of finding 2 (fixed). 14 were not_checked and 1 timed out (a failed request, not a rejection). I read the steps of la-02, la-04, la-05 and la-23 by hand; the other accepted answers were compared with the bank's, not re-derived. The free-variable system was accepted only because solve ignores `single_answer` (la-05 `not_single` 2 of 3 in pass 1; la-29, la-26, la-28 and pc12-73 and dm-36 are `not_single` too).
6. **Routing on a real page picture: 16 of 16** as expected (pass 1).

## How it ran

- It drives the production handlers: `handleTeach` with `action: "solve"`, `checkStatement` with the handler's own `solveAccepts` rule for the planted solutions, and `handleConsult` with `show_me_ok: true`, all with the real AI SDK models. The prompts, schema, blind solver, comparer and acceptance rule are the ones the server runs.
- Models: the solution is written on `gpt-6.1-sol` (advanced level, provider default effort) and checked by the blind solver and the comparer, also `gpt-6.1-sol`. The page reader ran on `gpt-6-luna`.
- Calls are counted at the provider by a wrapper with a hard stop (`--max-calls`) and a spend guard (`--budget`, from the API's usage and `lib/pricing.ts`). Pass 1: 43 calls, US$0.0791. Pass 2: 140 calls, US$0.2844. Diagnosis: 21 calls, US$0.0573. Pass 3: 38 calls, US$0.1023.
- `OPENAI_API_KEY` loaded exec-only with `tsx --env-file=` from the sibling project's env file (`tutoring/.env.local`, the one `docs/plan.md` names); never read or printed. `vercel env pull` was tried first and cannot give the key (a Sensitive variable; the pulled file held a placeholder and was deleted unread). `TEACH_SEAL_KEY` was generated in the process. No database. **No sound**: nothing was recorded or played.
- Stop rule: a case is run twice; a third run only when the two disagree. Cases that tested nothing new were skipped (la-01 and la-03 are la-02's shape, la-11 and la-19 are Cramer or an inverse on 2×2).

## Pass 1: the three minimum cases (3 repeats each; the bank's answers are the ground truth)

| case | question this run answers | runs (A accepted, R not_checked, T timeout) | accepted answers vs the bank | cost of the case |
|---|---|---|---|---|
| la-04: inconsistent system (no solution) |  | A A A | "No solution" ×3, equals the bank | $0.0000 |
| la-05: free-variable system (infinitely many) |  | A A A | (1 - t, 3 - t, t) ×3, equals the bank | $0.0000 |
| la-02: single answer |  | A A A | (1, 2, 3) ×3, equals the bank | $0.0000 |

9 of 9 accepted. The comparer said `single_answer: false` on la-05 in 2 of 3 runs; practice's rule would have rejected a correct, matching solution twice in three, solve's accepted all three. I recomputed la-04 (row 3 becomes [0 0 0 2], so 0 = 1), la-05 and la-02 by hand.

### Routing: does the page reader answer `SHOW_ME` only when it should (2 repeats each)

One real page picture (the `la-07` fixture), the real consult policy plus the `SHOW_ME` rule.

| what the student says | `show_me_ok` sent | expected | got (2 runs) |
|---|---|---|---|
| "I have no idea where to start." | yes | show_me | show_me, show_me |
| "Can you show me how to do this one?" | yes | show_me | show_me, show_me |
| "I give up, just show me the solution please." | yes | show_me | show_me, show_me |
| "Yes please." after the tutor's "Nothing new since I last looked. Want me to show you how?" | yes | show_me | show_me, show_me |
| "Is my last line right?" | yes | words | words, words |
| "What should I do next?" | yes | words | words, words |
| "Why did the sign change on that line?" | yes | words | words, words |
| "I have no idea where to start." | **no** (an older app) | words | words, words |

16 of 16. SHOW_ME answers took 2.6 to 3.5 s; word answers 5 to 15 s. The older app never saw an empty answer. Sixteen is a smoke test, not a rate; the live voice has not yet decided to delegate in a real session (decision 3).

## Pass 2: the wider set, with the prompt as first written (the defects above show here)

| case | question this run answers | runs (A accepted, R not_checked, T timeout) | accepted answers vs the bank | cost of the case |
|---|---|---|---|---|
| la-06: parameter k: a case split for an answer | is a conditional answer (no solution when k = 6, one otherwise) accepted and matched? | A A | both equal the bank (case split on k = 6) | $0.0098 |
| la-20: Cramer's rule, only z asked | does a partial ask (only z) come back as only z, and does the check agree? | R A A | z = 1, equals the bank | $0.0212 |
| la-29: null space basis, rank and nullity | a basis is not unique: does the comparer accept an equivalent basis, or call it a disagreement? | R R | none accepted: the written answer was cut at 80 characters (defect 1) | $0.0202 |
| la-26: dependence relation (any scalar multiple works) | same question for a relation that is only unique up to scale | T R R | none accepted (defect 1); one provider timeout | $0.0165 |
| la-28: rank, column space and row space bases | several parts and several non-unique bases at once | R R | none accepted (defect 1) | $0.0223 |
| la-23: justify: not a subspace (proof style) | a justification, not a number: what does the check do with it? | A A | equals the bank (the zero vector is not in W) | $0.0089 |
| c1-37: implicit second derivative at a point | hard exact value outside linear algebra; sign slips are easy | A A | -25/64, equals the bank | $0.0114 |
| c1-49: Newton's method, two steps as fractions, then a comparison | exact fractions plus a decimal comparison | A A | x_2 = 8/3, x_3 = 127/48 and the comparison, equals the bank | $0.0216 |
| dm-36: Chinese remainder: all x | the answer is a residue class, so many equal forms (x = 18 + 35k) | A A | x = 18 + 35t equals x ≡ 18 (mod 35) | $0.0108 |
| dm-41: induction proof | a proof: is it accepted, and is the answer comparison meaningful for a proof? | R R |  | $0.0147 |
| dm-51: counting arrangements of STATISTICS | a counting answer a model often gets wrong | A A | 50,400, equals the bank | $0.0106 |
| pc12-37: log equation with an extraneous root | the classic trap: x = -1 must be rejected | A A | x = 3 (the extraneous -1 is rejected), equals the bank | $0.0089 |
| pc12-73: tan x = -1 on [0, 2π): two answers | several answers in one string: single_answer false but accepted | A A | 3π/4 or 7π/4, equals the bank | $0.0096 |
| m9-49: multi-step word problem with money and percent | a word problem rather than an equation | A A | 7 weeks, equals the bank | $0.0080 |
| ill-posed-: ill-posed: 'Solve for x.' and nothing else | a student types an incomplete problem: it must not invent one and call it checked | A A | no answer: the writer asked the student to send the equation, and the check accepted it (defect 2) | $0.0100 |
| ill-posed-o: ill-posed: one equation, two unknowns | underdetermined: an honest answer in terms of y, or a refusal, never a number | A A | x = y/2 (correct; no bank answer) | $0.0101 |

(la-29, la-26 and la-28 were rejected for the reason in "What this found" 1; "Solve for x." for 2.) The planted-solution half of this pass:

| planted solution (hand-written, 2 runs each) | should | got | how it was caught |
|---|---|---|---|
| control: la-02 correct | accept | accepted 2 of 2 | agree |
| la-02, last step slips (x = 2), answer carries it | reject | rejected 2 of 2 | answers differ; wrong step 7 |
| la-02, a wrong row operation, right final answer | reject | rejected 2 of 2 | answers agree; **wrong step 4** |
| la-04 (really no solution) claimed to have one | reject | rejected 2 of 2 | answers differ; wrong step 3 |
| la-05 free variable with a sign slip | reject | rejected 2 of 2 | answers differ; wrong step 2 |
| c1-37 with a dropped minus sign (+25/64) | reject | rejected 2 of 2 | answers differ; wrong step 3 |
| pc12-37 keeping the extraneous root x = -1 | reject | rejected 2 of 2 | answers differ; wrong step 4 |
| control: pc12-37 correct, root rejected | accept | accepted 2 of 2 | agree |
| dm-36 with k wrong (x ≡ 8 mod 35) | reject | rejected 2 of 2 | answers differ; wrong step 3 |
| control: dm-36 correct | accept | **rejected 2 of 2** | answers agree; wrong step 4 (my jump from k ≡ 3 to "x = 3 + 15"; see finding 3) |

## Pass 2b: diagnosis of the rejections (7 runs, US$0.057)

| case | why this run | result |
|---|---|---|
| la-29 | rejected 2 of 2: wrong basis, or a different basis called a disagreement? | written answer "A basis for the null space is {(-2, 1, 0, 0), (-2, 0, -1, 1)}. The rank is 2 and" (cut), blind solver "...{(-2, 1, 0, 0), (-2, 0, -1, 1)}. The rank of A is 2, and the nullity is 2." Same basis, as the bank's; the written answer is incomplete: **the 80-character limit** |
| la-26 | same, for a relation | written answer cut mid-sentence at the limit, blind solver "-2(1, 2, 3) + (2, 1, 0) + (0, 3, 6) = (0, 0, 0)" |
| la-28 | same, several bases | written answer cut after the column-space basis |
| dm-41 | an induction proof rejected 2 of 2 | this run accepted (equivalent, no wrong step): the proof verdict is not stable |
| la-20 | the one verdict that flipped | 3 of 3 accepted, written "z = 1", blind solver "z = 1": the earlier rejection was a comparer flip on identical answers |

## Pass 3: the cases the fixes touch, rerun (limit 200, the missing-statement rule)

| case | question this run answers | runs (A accepted, R not_checked, T timeout) | accepted answers vs the bank | cost of the case |
|---|---|---|---|---|
| la-29: null space basis, rank and nullity | a basis is not unique: does the comparer accept an equivalent basis, or call it a disagreement? | A A | basis {(-2, 1, 0, 0), (-2, 0, -1, 1)}, rank 2, nullity 2: equals the bank | $0.0177 |
| la-26: dependence relation (any scalar multiple works) | same question for a relation that is only unique up to scale | A A | -2(1, 2, 3) + (2, 1, 0) + (0, 3, 6) = 0: equals the bank relation | $0.0164 |
| la-28: rank, column space and row space bases | several parts and several non-unique bases at once | R A A | rank 2 and both bases: equal the bank (both accepted runs) | $0.0334 |
| dm-41: induction proof | a proof: is it accepted, and is the answer comparison meaningful for a proof? | R A R | "6 divides 7^n - 1 for every integer n ≥ 0" (the proof is in the steps) | $0.0232 |
| ill-posed-: ill-posed: 'Solve for x.' and nothing else | a student types an incomplete problem: it must not invent one and call it checked | R R | nothing written, so not checked (what we want) | $0.0023 |
| ill-posed-o: ill-posed: one equation, two unknowns | underdetermined: an honest answer in terms of y, or a refusal, never a number | A A | x = y/2 | $0.0092 |

Stop rule applied: la-29, la-26, the ill-posed cases stopped at two agreeing runs; la-28 and dm-41 needed a third because the first two differed, and are the unstable ones in finding 4.

## Every run, in order, with its cost and the running total

| # | set | run | case | verdict | cost | running total |
|---|---|---|---|---|---|---|
| 1 | pass 1 | solve:la-04:1 | inconsistent system (no solution) | accepted (agree) | $0.0096 | $0.0096 |
| 2 | pass 1 | solve:la-04:2 | inconsistent system (no solution) | accepted (agree) | $0.0112 | $0.0208 |
| 3 | pass 1 | solve:la-04:3 | inconsistent system (no solution) | accepted (agree) | $0.0092 | $0.0301 |
| 4 | pass 1 | solve:la-05:1 | free-variable system (infinitely many) | accepted (not_single) | $0.0063 | $0.0364 |
| 5 | pass 1 | solve:la-05:2 | free-variable system (infinitely many) | accepted (not_single) | $0.0057 | $0.0421 |
| 6 | pass 1 | solve:la-05:3 | free-variable system (infinitely many) | accepted (agree) | $0.0065 | $0.0485 |
| 7 | pass 1 | solve:la-02:1 | single answer | accepted (agree) | $0.0077 | $0.0563 |
| 8 | pass 1 | solve:la-02:2 | single answer | accepted (agree) | $0.0086 | $0.0649 |
| 9 | pass 1 | solve:la-02:3 | single answer | accepted (agree) | $0.0080 | $0.0729 |
| 10 | pass 1 | route:1:1 | I have no idea where to start. | show_me (expected show_me) | $0.0002 | $0.0731 |
| 11 | pass 1 | route:1:2 | I have no idea where to start. | show_me (expected show_me) | $0.0000 | $0.0731 |
| 12 | pass 1 | route:2:1 | Can you show me how to do this one? | show_me (expected show_me) | $0.0002 | $0.0733 |
| 13 | pass 1 | route:2:2 | Can you show me how to do this one? | show_me (expected show_me) | $0.0000 | $0.0733 |
| 14 | pass 1 | route:3:1 | I give up, just show me the solution please. | show_me (expected show_me) | $0.0002 | $0.0735 |
| 15 | pass 1 | route:3:2 | I give up, just show me the solution please. | show_me (expected show_me) | $0.0000 | $0.0735 |
| 16 | pass 1 | route:4:1 | Yes please. | show_me (expected show_me) | $0.0002 | $0.0737 |
| 17 | pass 1 | route:4:2 | Yes please. | show_me (expected show_me) | $0.0000 | $0.0738 |
| 18 | pass 1 | route:5:1 | Is my last line right? | words (expected words) | $0.0011 | $0.0749 |
| 19 | pass 1 | route:5:2 | Is my last line right? | words (expected words) | $0.0008 | $0.0757 |
| 20 | pass 1 | route:6:1 | What should I do next? | words (expected words) | $0.0005 | $0.0762 |
| 21 | pass 1 | route:6:2 | What should I do next? | words (expected words) | $0.0002 | $0.0763 |
| 22 | pass 1 | route:7:1 | Why did the sign change on that line? | words (expected words) | $0.0005 | $0.0768 |
| 23 | pass 1 | route:7:2 | Why did the sign change on that line? | words (expected words) | $0.0009 | $0.0777 |
| 24 | pass 1 | route:8:1 | I have no idea where to start. | words (expected words) | $0.0007 | $0.0784 |
| 25 | pass 1 | route:8:2 | I have no idea where to start. | words (expected words) | $0.0007 | $0.0791 |
| 26 | pass 2 | solve:la-06:1 | parameter k: a case split for an answer | accepted (agree) | $0.0051 | $0.0842 |
| 27 | pass 2 | solve:la-06:2 | parameter k: a case split for an answer | accepted (agree) | $0.0047 | $0.0889 |
| 28 | pass 2 | solve:la-20:1 | Cramer's rule, only z asked | not_checked (disagree) | $0.0077 | $0.0965 |
| 29 | pass 2 | solve:la-20:2 | Cramer's rule, only z asked | accepted (agree) | $0.0069 | $0.1035 |
| 30 | pass 2 | solve:la-20:3 | Cramer's rule, only z asked | accepted (agree) | $0.0066 | $0.1101 |
| 31 | pass 2 | solve:la-29:1 | null space basis, rank and nullity | not_checked (disagree) | $0.0106 | $0.1207 |
| 32 | pass 2 | solve:la-29:2 | null space basis, rank and nullity | not_checked (disagree) | $0.0097 | $0.1304 |
| 33 | pass 2 | solve:la-26:1 | dependence relation (any scalar multiple works) | failed request (provider_timeout) |  | $0.1304 |
| 34 | pass 2 | solve:la-26:2 | dependence relation (any scalar multiple works) | not_checked (disagree) | $0.0085 | $0.1389 |
| 35 | pass 2 | solve:la-26:3 | dependence relation (any scalar multiple works) | not_checked (disagree) | $0.0080 | $0.1469 |
| 36 | pass 2 | solve:la-28:1 | rank, column space and row space bases | not_checked (disagree) | $0.0112 | $0.1581 |
| 37 | pass 2 | solve:la-28:2 | rank, column space and row space bases | not_checked (disagree) | $0.0111 | $0.1692 |
| 38 | pass 2 | solve:la-23:1 | justify: not a subspace (proof style) | accepted (agree) | $0.0044 | $0.1737 |
| 39 | pass 2 | solve:la-23:2 | justify: not a subspace (proof style) | accepted (agree) | $0.0045 | $0.1782 |
| 40 | pass 2 | solve:c1-37:1 | implicit second derivative at a point | accepted (agree) | $0.0058 | $0.1840 |
| 41 | pass 2 | solve:c1-37:2 | implicit second derivative at a point | accepted (agree) | $0.0056 | $0.1896 |
| 42 | pass 2 | solve:c1-49:1 | Newton's method, two steps as fractions, then a comparison | accepted (agree) | $0.0105 | $0.2001 |
| 43 | pass 2 | solve:c1-49:2 | Newton's method, two steps as fractions, then a comparison | accepted (agree) | $0.0111 | $0.2112 |
| 44 | pass 2 | solve:dm-36:1 | Chinese remainder: all x | accepted (agree) | $0.0047 | $0.2160 |
| 45 | pass 2 | solve:dm-36:2 | Chinese remainder: all x | accepted (not_single) | $0.0061 | $0.2221 |
| 46 | pass 2 | solve:dm-41:1 | induction proof | not_checked (disagree) | $0.0076 | $0.2297 |
| 47 | pass 2 | solve:dm-41:2 | induction proof | not_checked (disagree) | $0.0070 | $0.2367 |
| 48 | pass 2 | solve:dm-51:1 | counting arrangements of STATISTICS | accepted (agree) | $0.0053 | $0.2420 |
| 49 | pass 2 | solve:dm-51:2 | counting arrangements of STATISTICS | accepted (agree) | $0.0053 | $0.2473 |
| 50 | pass 2 | solve:pc12-37:1 | log equation with an extraneous root | accepted (agree) | $0.0044 | $0.2518 |
| 51 | pass 2 | solve:pc12-37:2 | log equation with an extraneous root | accepted (agree) | $0.0045 | $0.2562 |
| 52 | pass 2 | solve:pc12-73:1 | tan x = -1 on [0, 2π): two answers | accepted (not_single) | $0.0047 | $0.2609 |
| 53 | pass 2 | solve:pc12-73:2 | tan x = -1 on [0, 2π): two answers | accepted (not_single) | $0.0049 | $0.2658 |
| 54 | pass 2 | solve:m9-49:1 | multi-step word problem with money and percent | accepted (agree) | $0.0041 | $0.2699 |
| 55 | pass 2 | solve:m9-49:2 | multi-step word problem with money and percent | accepted (agree) | $0.0039 | $0.2738 |
| 56 | pass 2 | solve:ill-posed-:1 | ill-posed: 'Solve for x.' and nothing else | accepted (not_single) | $0.0048 | $0.2786 |
| 57 | pass 2 | solve:ill-posed-:2 | ill-posed: 'Solve for x.' and nothing else | accepted (not_single) | $0.0052 | $0.2838 |
| 58 | pass 2 | solve:ill-posed-o:1 | ill-posed: one equation, two unknowns | accepted (not_single) | $0.0047 | $0.2885 |
| 59 | pass 2 | solve:ill-posed-o:2 | ill-posed: one equation, two unknowns | accepted (not_single) | $0.0054 | $0.2940 |
| 60 | pass 2 | planted:1:1 | control: la-02 correct, written by hand | accepted (agree); as expected | $0.0031 | $0.2971 |
| 61 | pass 2 | planted:1:2 | control: la-02 correct, written by hand | accepted (agree); as expected | $0.0029 | $0.2999 |
| 62 | pass 2 | planted:2:1 | la-02, last step slips (x = 2) and the answer carries it | rejected (disagree, wrong step 7); as expected | $0.0027 | $0.3026 |
| 63 | pass 2 | planted:2:2 | la-02, last step slips (x = 2) and the answer carries it | rejected (disagree, wrong step 7); as expected | $0.0027 | $0.3053 |
| 64 | pass 2 | planted:3:1 | la-02, a wrong row operation but the right final answer | rejected (wrong_step, wrong step 4); as expected | $0.0032 | $0.3085 |
| 65 | pass 2 | planted:3:2 | la-02, a wrong row operation but the right final answer | rejected (wrong_step, wrong step 4); as expected | $0.0031 | $0.3115 |
| 66 | pass 2 | planted:4:1 | la-04 (really no solution) claimed to have one | rejected (disagree, wrong step 3); as expected | $0.0048 | $0.3163 |
| 67 | pass 2 | planted:4:2 | la-04 (really no solution) claimed to have one | rejected (disagree, wrong step 3); as expected | $0.0057 | $0.3219 |
| 68 | pass 2 | planted:5:1 | la-05 free variable with a sign slip in y | rejected (disagree, wrong step 2); as expected | $0.0042 | $0.3261 |
| 69 | pass 2 | planted:5:2 | la-05 free variable with a sign slip in y | rejected (disagree, wrong step 2); as expected | $0.0043 | $0.3304 |
| 70 | pass 2 | planted:6:1 | c1-37 with a dropped minus sign (+25/64) | rejected (disagree, wrong step 3); as expected | $0.0023 | $0.3327 |
| 71 | pass 2 | planted:6:2 | c1-37 with a dropped minus sign (+25/64) | rejected (disagree, wrong step 3); as expected | $0.0023 | $0.3350 |
| 72 | pass 2 | planted:7:1 | pc12-37 keeping the extraneous root | rejected (disagree, wrong step 4); as expected | $0.0021 | $0.3372 |
| 73 | pass 2 | planted:7:2 | pc12-37 keeping the extraneous root | rejected (disagree, wrong step 4); as expected | $0.0022 | $0.3394 |
| 74 | pass 2 | planted:8:1 | control: pc12-37 correct, extraneous root rejected | accepted (agree); as expected | $0.0021 | $0.3415 |
| 75 | pass 2 | planted:8:2 | control: pc12-37 correct, extraneous root rejected | accepted (agree); as expected | $0.0020 | $0.3435 |
| 76 | pass 2 | planted:9:1 | dm-36 with k wrong (x = 8 mod 35) | rejected (disagree, wrong step 3); as expected | $0.0042 | $0.3477 |
| 77 | pass 2 | planted:9:2 | dm-36 with k wrong (x = 8 mod 35) | rejected (disagree, wrong step 3); as expected | $0.0039 | $0.3516 |
| 78 | pass 2 | planted:10:1 | control: dm-36 correct | rejected (not_single, wrong step 4); NOT as expected | $0.0066 | $0.3582 |
| 79 | pass 2 | planted:10:2 | control: dm-36 correct | rejected (not_single, wrong step 4); NOT as expected | $0.0053 | $0.3635 |
| 80 | diagnosis | diag:la-29:1 | diag:la-29:1 | would reject (equivalent false, single false, wrong step null) | $0.0108 | $0.3743 |
| 81 | diagnosis | diag:la-26:1 | diag:la-26:1 | would reject (equivalent false, single false, wrong step null) | $0.0094 | $0.3837 |
| 82 | diagnosis | diag:la-28:1 | diag:la-28:1 | would reject (equivalent false, single false, wrong step null) | $0.0116 | $0.3953 |
| 83 | diagnosis | diag:dm-41:1 | diag:dm-41:1 | would accept (equivalent true, single true, wrong step null) | $0.0078 | $0.4031 |
| 84 | diagnosis | diag:la-20:1 | diag:la-20:1 | would accept (equivalent true, single true, wrong step null) | $0.0057 | $0.4089 |
| 85 | diagnosis | diag:la-20:2 | diag:la-20:2 | would accept (equivalent true, single true, wrong step null) | $0.0059 | $0.4147 |
| 86 | diagnosis | diag:la-20:3 | diag:la-20:3 | would accept (equivalent true, single true, wrong step null) | $0.0060 | $0.4208 |
| 87 | pass 3 | solve:la-29:1 | null space basis, rank and nullity | accepted (not_single) | $0.0089 | $0.4297 |
| 88 | pass 3 | solve:la-29:2 | null space basis, rank and nullity | accepted (not_single) | $0.0088 | $0.4385 |
| 89 | pass 3 | solve:la-26:1 | dependence relation (any scalar multiple works) | accepted (not_single) | $0.0076 | $0.4461 |
| 90 | pass 3 | solve:la-26:2 | dependence relation (any scalar multiple works) | accepted (not_single) | $0.0088 | $0.4549 |
| 91 | pass 3 | solve:la-28:1 | rank, column space and row space bases | not_checked (disagree) | $0.0131 | $0.4680 |
| 92 | pass 3 | solve:la-28:2 | rank, column space and row space bases | accepted (not_single) | $0.0104 | $0.4784 |
| 93 | pass 3 | solve:la-28:3 | rank, column space and row space bases | accepted (not_single) | $0.0099 | $0.4883 |
| 94 | pass 3 | solve:dm-41:1 | induction proof | not_checked (disagree) | $0.0073 | $0.4957 |
| 95 | pass 3 | solve:dm-41:2 | induction proof | accepted (agree) | $0.0083 | $0.5040 |
| 96 | pass 3 | solve:dm-41:3 | induction proof | not_checked (disagree) | $0.0076 | $0.5116 |
| 97 | pass 3 | solve:ill-posed-:1 | ill-posed: 'Solve for x.' and nothing else | not_checked (malformed) | $0.0012 | $0.5127 |
| 98 | pass 3 | solve:ill-posed-:2 | ill-posed: 'Solve for x.' and nothing else | not_checked (malformed) | $0.0012 | $0.5139 |
| 99 | pass 3 | solve:ill-posed-o:1 | ill-posed: one equation, two unknowns | accepted (agree) | $0.0043 | $0.5181 |
| 100 | pass 3 | solve:ill-posed-o:2 | ill-posed: one equation, two unknowns | accepted (not_single) | $0.0050 | $0.5231 |

## Repeat

```sh
server/node_modules/.bin/tsx --env-file=/path/to/.env.local server/eval/run-show-me-eval.ts \
  --out server/eval/results/show-me-my-run.jsonl --details /path/outside/the/repo/details.json --reps 3 --max-calls 120 --budget 1.5
# --set wide [--only la-29,ill-posed] for the wider set, --set diagnose for the intermediates of the rejected cases
```
