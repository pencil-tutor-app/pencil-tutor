# App Store: setting up the in-app subscription

Click-steps for Edward, for an **individual** Apple Developer account (Edward's own, not a company). Why the subscription exists and how
it works: `docs/plan.md`, amendment 20. Nothing in the code is tied to an account: every account-dependent value is a blank in the
table below that goes into two places (the server's Vercel settings and the app's `ios/Config/Secrets.xcconfig`).

Two things that come with an individual account:
- **The App Store shows your legal name as the seller** on the app page (a company account shows the company name). It is not hidden
  and cannot be changed to a trade name without enrolling as an organization. If that matters to you, decide before the first release.
- An app can be transferred to an organization account later (App Store Connect, app, App Information, Transfer App). The bundle id and
  product id stay the same, so only the server's settings that name the Apple app id would need re-checking. Subscriptions are the
  harder part to move; check Apple's current transfer rules before relying on it.

Menu names in App Store Connect move around; the words below are what they were when this was written (2026-11).

## The values (fill these in as you create things)

| value | where it comes from | server setting (Vercel) | app setting (`Secrets.xcconfig`) |
|---|---|---|---|
| Bundle id: ______________________ | you choose it when you register the app id, for example `com.edwardtran.penciltutor` | `APPLE_BUNDLE_ID` | `APP_BUNDLE_ID` |
| Product id: ______________________ | you choose it when you create the subscription; the default used in code and in the Xcode test file is `penciltutor.monthly`. It can never be reused after the product is deleted | `APPLE_IAP_PRODUCT_ID` | `IAP_PRODUCT_ID` |
| App Apple id: ______________________ | a number, shown in App Store Connect, app, App Information, "Apple ID" (appears once the app record exists) | `APPLE_APP_APPLE_ID` | not needed |
| Team id: ______________________ | developer.apple.com, Membership details (10 characters) | not needed | `DEVELOPMENT_TEAM` |
| Environments | `sandbox` until the app is approved, then `production,sandbox` for review and launch (see step 9) | `APPLE_IAP_ENVIRONMENTS` | not needed |
| Terms of Use page: ______________________ | a web page you publish | not needed | `TERMS_URL` |
| Privacy Policy page: ______________________ | a web page you publish | not needed | `PRIVACY_POLICY_URL` |

Optional server settings: `IAP_MONTHLY_MINUTES` (default 480) and `APPLE_ONLINE_CHECKS=0` (turns off Apple's certificate revocation
check; leave it on).

In an `.xcconfig` file `//` starts a comment, so write a page address as `https:/$()/example.com/terms`.

## Steps

### 1. Join the Apple Developer Program as an individual
developer.apple.com/programs, Enroll, "Individual / Sole Proprietor". It costs US$99 a year. Apple asks for your legal name and checks
your identity. You must be the Account Holder to do the agreements below.

### 2. Sign the Paid Apps Agreement, tax and banking (needed before any subscription can be sold)
App Store Connect, Business (called Agreements, Tax, and Banking in older menus). Accept the **Paid Apps Agreement**, add a bank
account (Canadian account for CAD payouts), and fill the tax forms for Canada. Until its status is Active, products cannot be tested
as purchasable by real users, and the app cannot be approved with a subscription.

### 3. Register the bundle id and create the app
1. developer.apple.com, Certificates, Identifiers & Profiles, Identifiers, add an **App ID**, type App, with your bundle id. Leave
   capabilities at their defaults (In-App Purchase needs no switch on iOS).
2. App Store Connect, Apps, plus, **New App**: platform iOS, name "Pencil Tutor" (must be unique on the App Store; if it is taken, the
   display name can differ from the Home Screen name), primary language, the bundle id from step 1, an SKU of your choice
   (for example `penciltutor-ios`). The app is iPad only: in the build settings the device family is already 2.
3. Open the app, App Information, and copy the numeric **Apple ID**: that is `APPLE_APP_APPLE_ID`.

### 4. Create the subscription
1. In the app's sidebar, Monetization, **Subscriptions**. Create a **Subscription Group** named "Pencil Tutor".
2. In the group, create a subscription:
   - Reference name: `Pencil Tutor monthly` (only you see it).
   - **Product ID**: your product id from the table (the default is `penciltutor.monthly`).
   - Subscription duration: **1 month**.
   - Subscription prices: base country Canada, choose the price point closest to **CA$19.00**; Apple fills in other countries from it.
     The app shows whatever price the App Store returns, so write down the exact Canadian price you picked in `docs/plan.md`.
   - Localization (English, Canada or US): display name "Pencil Tutor monthly", description "Eight hours of tutoring each month."
   - Family Sharing: **off** (a shared subscription would let one payment unlock several Apple accounts).
   - Review information: a screenshot of the code screen that shows the Subscribe button, and a one-line note.
3. The subscription starts as "Missing Metadata" until the above is complete. It goes to review together with the first app version
   (step 10), by ticking it under the version's "In-App Purchases and Subscriptions".
4. Leave **grace period** and billing retry options at their defaults. The server's rules assume access ends at the paid period's end
   (plan amendment 20); do not add offers, free trials or other subscriptions without asking first: the server accepts exactly one
   product id.

### 5. Small Business Program (15% instead of 30%)
developer.apple.com/app-store/small-business-program, Enroll. You must be the Account Holder and the Paid Apps Agreement must be
Active. It applies from the next fiscal month after Apple accepts it. Eligible while your proceeds across all related accounts stay under
US$1 million a year.

### 6. Server notifications (renewals, expiry, refunds)
App Store Connect, the app, **App Information**, scroll to **App Store Server Notifications**.
- Production Server URL: `https://<the deployed server>/api/app-store-notifications`, version **Version 2**.
- Sandbox Server URL: the same address, version **Version 2**.
(The deployed server is the Vercel project `pencil-tutor`; `SERVER_URL` in the app's xcconfig is its address.) Apple signs every
notification and the server verifies it, so the address needs no secret. Apple retries a notification that did not get a 200 for
several days; the server answers 503 when its database is down so nothing is lost. A TEST notification, if you ever send one
through the App Store Server API, is answered 200 and logged as `ignored:TEST`.

### 7. Sandbox tester (no real money)
App Store Connect, **Users and Access**, Sandbox, Test Accounts, add a tester with an email address that is **not** an existing Apple
Account. On the iPad, Settings, Developer, Sandbox Apple Account, sign in with it (or sign in when the purchase sheet asks). Sandbox
subscriptions renew every few minutes (a "month" is about 5 minutes) and stop renewing after a handful of renewals; that is how renewal
and expiry get tested quickly.

### 8. Put the settings in place (nothing here is committed)
1. **Database first.** `server/scripts/codes migrate` adds the subscription columns and table (additive). Run it **before** deploying
   this version of the server: the code check reads the new columns, so a server deployed first would answer 503 for every student.
2. Vercel, project `pencil-tutor`, Settings, Environment Variables (Production): `APPLE_IAP_PRODUCT_ID`, `APPLE_BUNDLE_ID`,
   `APPLE_APP_APPLE_ID`, `APPLE_IAP_ENVIRONMENTS=sandbox`. Then deploy. Check `GET /api/health`: `subscription.configured` should be
   `true` and list the environments (it never shows the values).
3. `ios/Config/Secrets.xcconfig` (git-ignored): `APP_BUNDLE_ID`, `IAP_PRODUCT_ID`, `DEVELOPMENT_TEAM`, optionally `TERMS_URL`,
   `PRIVACY_POLICY_URL`. Run `xcodegen generate` in `ios/` and put `DEVELOPMENT_TEAM` back if the generated project lost it.

### 9. Test it
- **In Xcode, no Apple account:** run the PencilTutor scheme; it already uses `ios/StoreKit/PencilTutor.storekit` (CA$19, monthly). The
  Subscribe and Restore screens work and Debug, Manage Transactions (Xcode, Debug menu, StoreKit) can renew, expire and refund. The
  server will answer 422 to these purchases by design (Apple did not sign them), so the app says it could not finish setting up.
- **Sandbox, with the server:** a TestFlight build, or a development build signed with your team, plus the sandbox tester of step 7.
  Tap Subscribe, confirm with the sandbox account. Expect a working code, 480 minutes, and `purchase` log lines with
  `subscription: created`. Wait for a sandbox renewal: a `app-store-notifications` line with `notification_type: DID_RENEW` and
  `top_up: topped_up`. Delete the app, reinstall, tap Restore Purchases: the same code comes back (`subscription: existing`).
- **Review and launch:** App Review's purchases are sandbox transactions even though the server is the production one, so set
  `APPLE_IAP_ENVIRONMENTS=production,sandbox` before submitting. After approval you may drop `sandbox` (a sandbox purchase makes a real
  working code for free, though only someone with a sandbox or TestFlight account can make one).

### 10. Submit the app
- App Privacy: the app asks for no name or contact details; the server keeps a random code and minutes used, and receives page
  pictures and voice recordings for tutoring. Answer the questionnaire to match what the server really does with them (the server
  logs sizes and counts only, never their content; the AI providers' own retention is a separate answer to check).
- Add the Terms of Use and Privacy Policy addresses (Apple expects both for an auto-renewing subscription). The privacy policy goes in
  App Information. Terms: either the app description or a custom EULA (App Information, License Agreement).
- Tick the subscription under the version's "In-App Purchases and Subscriptions" and submit.
- **Review notes** (App Review Information, Notes). Paste, then fill the blanks:

  > Pencil Tutor is a math tutoring service for students of a private tutor. The student writes on the iPad with Apple Pencil and a
  > tutor watches and helps. The service is multiplatform in the sense of guideline 3.1.3(b): the same tutoring time that a student
  > is given a code for by the tutor can also be bought in the app. The Subscribe button on the first screen offers the auto-renewing
  > subscription "Pencil Tutor monthly" (8 hours of tutoring a month) through In-App Purchase, and Restore Purchases is on the same
  > screen. The app does not mention or link to any other way to pay.
  >
  > To test without paying you can type this code on the first screen: ____-____ (valid for 8 hours of use). To test the subscription,
  > tap Subscribe and confirm with a sandbox account.

  Make that reviewer code with `server/scripts/codes create --hours 8` and disable it after approval
  (`server/scripts/codes disable CODE`). Do not put the real code in a document that is committed.

## When something goes wrong

Every request logs one line with reason labels and hashed ids (never the signed transaction or the code).

| what you see | meaning |
|---|---|
| `/api/purchase` 503 `iap_not_configured`, reason names a setting | that environment variable is missing or malformed on the server |
| 422 `wrong_app` / `bundle_id_mismatch` | `APPLE_BUNDLE_ID` does not equal the app's bundle id, or the build uses a different `APP_BUNDLE_ID` |
| 422 `wrong_product` / `product_not_ours` | the product id in the app (`IAP_PRODUCT_ID`) differs from the server's (`APPLE_IAP_PRODUCT_ID`) |
| 422 `environment_not_accepted` | a sandbox (or production) purchase arrived and `APPLE_IAP_ENVIRONMENTS` does not list it |
| 422 `invalid_transaction` / `signature_invalid` | not signed by Apple: an Xcode StoreKit test purchase, or a tampered string |
| 503 `apple_check_unavailable` | Apple's certificate check could not run (network); the app retries on the next launch |
| 403 `subscription_not_active` | the transaction the app sent has expired or was refunded; the app stops retrying it |
| students see "This code has been turned off" and the log reason is `the subscription behind this code has ended` | the paid period ended (or was refunded) |
| 503 `database_unavailable` on everything after a deploy | the server was deployed before `scripts/codes migrate` (step 8) |
