import { handleFreeCode } from "../lib/free-code.js";

export const POST = (request: Request) => handleFreeCode(request);
// Any other method answers 405.
export const GET = POST;
