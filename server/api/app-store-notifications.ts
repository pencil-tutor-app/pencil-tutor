import { defaultDeps } from "../lib/gate.js";
import { handleAppStoreNotification } from "../lib/purchase.js";

// Apple calls this (App Store Server Notifications V2). Set its address in App Store Connect: docs/app-store.md.
export const POST = (request: Request) => handleAppStoreNotification(request, defaultDeps());
// Any other method answers 405, same as the other endpoints.
export const GET = POST;
