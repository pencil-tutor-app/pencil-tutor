import { handleTeach } from "../lib/teach.js";

// POST is the real method; GET is exported only so an unauthenticated GET answers 401 instead of the platform's 405.
export const POST = (request: Request) => handleTeach(request);
export const GET = POST;
