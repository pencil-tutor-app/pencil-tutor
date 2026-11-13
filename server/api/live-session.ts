import { handleLiveSession } from "../lib/live.js";

// POST is the real method; GET is exported only so an unauthenticated GET answers 401 instead of the platform's 405.
export const POST = (request: Request) => handleLiveSession(request);
export const GET = POST;
