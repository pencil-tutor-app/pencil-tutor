import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { checkRecording, parseVoiceId, VOICE_NAME } from "../scripts/clone-voice.js";

// The clone script itself is not run in tests (it would create a voice); these check its pure parts.
describe("clone-voice script", () => {
  it("is named Edward Tutor", () => {
    assert.equal(VOICE_NAME, "Edward Tutor");
  });

  it("reads the voice id from the reply and nothing else", () => {
    assert.equal(parseVoiceId('{"voice_id":"abcDEF1234567890xyz","requires_verification":false}'), "abcDEF1234567890xyz");
    assert.equal(parseVoiceId('{"requires_verification":false}'), null);
    assert.equal(parseVoiceId("not json"), null);
    assert.equal(parseVoiceId('{"voice_id":"has spaces and ../"}'), null);
  });

  it("refuses a missing argument and a file that does not exist", () => {
    assert.equal(checkRecording(undefined).ok, false);
    const missing = checkRecording("/no/such/recording.m4a");
    assert.deepEqual(missing, { ok: false, reason: "that file does not exist" });
  });
});
