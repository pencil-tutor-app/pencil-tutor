import { handlePrivacy } from "../lib/record/endpoint.js";

export const GET = (request: Request) => handlePrivacy(request);
