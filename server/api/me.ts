import { handleMe } from "../lib/me.js";

export const GET = (request: Request) => handleMe(request);
// Any other method answers 405 (after the code is checked), same as the other endpoints.
export const POST = GET;
