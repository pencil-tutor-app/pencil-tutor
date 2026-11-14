import { defaultDeps } from "../lib/gate.js";
import { handlePurchase } from "../lib/purchase.js";

export const POST = (request: Request) => handlePurchase(request, defaultDeps());
// Any other method answers 405, same as the other endpoints.
export const GET = POST;
