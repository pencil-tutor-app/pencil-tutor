import { handleHealth } from "../lib/health.js";

export const GET = (request: Request) => handleHealth(request);
