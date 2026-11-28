# Show me how on Edward's iPad, silent (2026-11-28)

The server was deployed from `main` after #6 merged (Vercel deployment `pencil-tutor-f0tjyf5jy`; `/api/health` ok, `teach_ready` true, an unauthenticated `solve` gets 401). The app was the CI artifact `PencilTutor-iphoneos-Debug-unsigned` from run 46161639500 (#7). It was re-signed on the Mac with the free Apple ID's identity and its Xcode profile, then installed with `devicectl`. No local build, simulator or sound.

Launch: `--silent --open-problem la-02 --qa-show-me "show@12,like@30,show@80" --ui-snapshots "landscape@20,landscape@65,landscape@95"`. Session `4da23fbe`; the raw log stays off the repo.

| s after launch | event | result |
|---|---|---|
| 13.6 | Show me how pressed on la-02 | `show_me_shown`: 7 steps, stored, 958 ms |
| 14.8 to 22.2 | base voice line (muted) | ElevenLabs, first audio 1,092 ms |
| 32.3 to 47.2 | Try one like it | `like_it_ready` in 14.9 s (gpt-6.1-sol, checked), `problem_swapped` to a teach page |
| 82.6 | Show me how pressed on the new page | `show_me_shown`: 8 steps, from the sealed reference, 503 ms |

Pictures: [la-02 with the panel](assets/show-me-la-02-panel.jpg), [the new problem](assets/show-me-like-it-page.jpg), [the new problem's solution](assets/show-me-practice-panel.jpg). The new problem (x + 2y + z = 4, 2x + y − z = −1, x + 3y − 2z = −9) was checked by hand: x = 2, y = −1, z = 4 satisfies all three equations, and every row operation in the panel is right.

Seen, not fixed:
- The open panel covers the right end of the action pill. Show me how is hidden while its own panel is open, and the panel closes with its X.
- The generated problem writes "-" where the bank writes "−". Both are typeset the same way.
- `ui_orientation_error` on every picture: the iPad's windowing mode refuses programmatic rotation. The pictures are the iPad's current layout.

Not covered here: ink on the swapped page and its look (CI `ShowMeUITests` covers this on a simulator), and the spoken path. Silent mode does not open live voice, so "I have no idea, show me" said to the voice has no device receipt until Edward's next session.
