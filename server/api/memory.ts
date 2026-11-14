import { handleMemoryAction, handleMemoryStatus } from "../lib/record/endpoint.js";

export const GET = (request: Request) => handleMemoryStatus(request);
export const POST = (request: Request) => handleMemoryAction(request);
