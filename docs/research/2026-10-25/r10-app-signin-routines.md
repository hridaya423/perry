# R10: Perry-owned app sign-in, and routines in onboarding

Date: 2026-10-25. Scope: research and read-only code audit. No build, no launch, no OAuth registration, no sign-in.
Marks: **(inference)** is my conclusion, not a sourced fact. **(unverified)** is a claim from a secondary source or one I could not confirm. Web claims carry a URL. Code claims carry `path:line`.

---

## 0. Decisions in one page

1. **Google will not accept Perry's current redirect.** Google says "Custom URI schemes are no longer supported" for Desktop clients ([Google native-app guide](https://developers.google.com/identity/protocols/oauth2/native-app)). Perry uses `dev.perry.perry:/oauth/callback` (`App/RemoteIntegrations.swift:892`). A Google "Perry-owned" client needs a loopback listener on `http://127.0.0.1:<port>`. This is new code in `OAuthCoordinator`.
2. **No domain, no Google, no Notion listing.** Google verification needs a verified domain, a public home page and a privacy policy on that domain ([sensitive scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification)). `PRD.md:188` lists "domain + social handles for Perry" as still open. Buy the domain first.
3. **Ship order by effort:**
   - **Days:** Linear (PKCE, no secret), Slack (PKCE is GA since March 2026, with caveats), GitHub (device flow, no secret), Calendar through macOS EventKit (no OAuth at all).
   - **Weeks:** Google Calendar and Drive-by-file (sensitive or non-sensitive scopes), Notion (needs a client secret in the binary plus a listing review), Microsoft 365 (free to register; verified publisher needs a Partner account and a work tenant).
   - **Months or never:** Gmail read and full Drive read. Both are *restricted* scopes. A CASA security assessment probably applies, because Perry sends mail text to the user's chosen cloud model **(inference)**.
4. **Biggest finding for the "no backend" rule:** vendor-hosted MCP servers with OAuth. Linear's server supports "OAuth 2.1 with dynamic client registration" ([Linear MCP](https://linear.app/docs/mcp)). Perry would not register an app with Linear at all. The MCP spec now prefers Client ID Metadata Documents and keeps DCR as a deprecated fallback ([MCP authorization spec](https://modelcontextprotocol.io/specification/draft/basic/authorization)). Perry's MCP client supports only a static bearer token today (`App/CustomConnectors.swift:193-194`). Adding MCP OAuth would cover Linear now and other vendors as they follow. Slack and GitHub hosted MCP servers appear to need pre-registered clients **(unverified)**.
5. **Gmail interim:** keep the bring-your-own client path, but make it a guided wizard. For users who want zero setup, read mail through Mail.app with Automation permission **(inference, untested)**. Reject IMAP plus app password. Reject brokers as the default.
6. **Brokers fail the no-backend rule in practice.** Pipedream says "Never expose secrets in your client-side code" ([Pipedream Connect](https://pipedream.com/docs/connect)). A desktop app with no server would put the broker key in the binary. Every message and file would then flow through the vendor. Smithery's connection service shuts down on 31 October 2026 ([Smithery](https://smithery.ai/future)).
7. **Routines: replay is real but narrow.** The typed-plan engine is safe. The recorder is thin. Replay resolves *every* step against *one* screen snapshot taken before step 1 (`Packages/PerryGuide/Sources/PerryGuide/RoutineReplay.swift:57-110`, targets resolved in the loop at `:124`). Any step that targets a control that appears only after an earlier step fails before anything runs. The repo holds no live success data for it.
8. **Onboarding beat for routines: yes, but after the first goal, optional, and honest.** Offer "Show me something you do often" only after the user finishes one real task. Limit the pitch to one-window flows until the replay bugs in section 3.6 are fixed. Copy is in section 3.8.
9. **Surprise worth reading first:** `docs/capabilities.md:77-79` says the recorder captures "steps and structure, not your keystrokes' values". The code stores typed text as a literal in the routine file unless the user flips a toggle (`Packages/PerryGuide/Sources/PerryGuide/LearnedRoutine.swift:282`, `App/RoutineLibraryController.swift:160-175`). Fix the doc or change the default before any onboarding promotes the feature.

---

## 1. Part 1: OAuth for a native app with no backend

### 1.1 Summary table

| Provider | Public client (no secret)? | Redirect options | Read-first scope | Review gate | Verdict |
|---|---|---|---|---|---|
| Google Calendar | Yes. Desktop client, secret optional, PKCE advised | Loopback only | `calendar.readonly` (sensitive) | Sensitive verification, "typically 3-5 business days" after prerequisites | Weeks (domain first) |
| Google Drive | Same | Same | `drive.file` is non-sensitive. `drive.readonly` is **restricted** | Restricted: weeks to months, CASA likely | `drive.file` only: weeks. Full read: months |
| Gmail | Same | Same | `gmail.readonly` is **restricted** (`gmail.compose` too) | Restricted verification plus CASA if data touches a third-party server | Months or never |
| Notion | **No.** Basic auth with client secret on token and refresh | Not documented (see 1.2.2) | None. Capabilities set in the dashboard | Public connection "submitted for review" | Weeks, secret ships in binary |
| Slack | **Yes since March 2026** (opt-in, one-way) | Custom scheme allowed. Localhost allowed when PKCE is on | User scopes only. No bot scopes for desktop redirects | Unlisted distribution works. Rate limits are harsh | Days, with caveats |
| Linear | **Yes.** `client_secret` optional with PKCE | Not documented. Test at registration | `read` | None documented | Days |
| GitHub | Device flow needs no secret. Web flow needs the secret | Loopback with any port. Custom scheme not documented | OAuth App `repo` is coarse. GitHub App is finer | None for OAuth Apps | Days (device flow) |
| Microsoft Graph | **Yes.** Public client must not use a secret | `http://localhost` (port ignored) | `Mail.Read`, `Calendars.Read`, `Files.Read`, `offline_access` | Publisher verification advised | Days unverified, weeks verified |

### 1.2 Per provider

#### 1.2.1 Google (Gmail, Calendar, Drive, Docs, Sheets)

**Registration.** Create a Cloud project, configure the consent screen, create a client of type **Desktop app** ([native-app guide](https://developers.google.com/identity/protocols/oauth2/native-app)).

**Secret.** The guide says "Desktop apps are public clients and cannot keep secrets confidential." The `client_secret` is optional in token and refresh requests. PKCE: "Always use PKCE." Shipping the Desktop client ID, and a secret if Google issues one, is the intended pattern. Google does not treat that secret as secret.

**Redirect.** Loopback (`http://127.0.0.1:port`) is "supported, recommended" for macOS. Custom URI schemes and out-of-band copy-paste are "no longer supported" for Desktop clients. A secondary README from AppAuth says macOS may use a reversed-client-ID custom scheme ([AppAuth Google example](https://github.com/valdperformance/AppAuth-iOS/blob/master/Examples/README-Google.md)). That README is old and conflicts with Google's current page **(unverified)**. Plan for loopback.

**Scope classes** (from Google's pages):

| Scope | Class | Source |
|---|---|---|
| `gmail.readonly`, `gmail.compose`, `gmail.modify`, `gmail.metadata`, `mail.google.com` | Restricted | [Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes) |
| `gmail.send` | Sensitive | same |
| `calendar`, `calendar.readonly`, `calendar.events`, `calendar.events.readonly` | Sensitive | [Nylas summary, 2021](https://www.nylas.com/blog/google-oauth-app-verification/) **(secondary, dated)** |
| `drive.file`, `drive.appdata` | Non-sensitive | [Drive scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth) |
| `drive.readonly`, `drive.metadata.readonly`, `drive` | Restricted | same |
| `documents.readonly`, `spreadsheets.readonly` | Not confirmed in this pass | Google says any scope not restricted is sensitive, so expect sensitive **(inference)** |

Perry's catalog requests `drive.readonly` and `gmail.readonly` (`App/RemoteIntegrations.swift:848-849`). Both are restricted. Today's scope list cannot get past the unverified wall without a restricted review.

**Verification and caps.**
- Unverified apps that request sensitive or restricted scopes show a warning screen and hit a 100-user cap. The cap is lifetime and tied to the project, per secondary sources ([Unipile](https://www.unipile.com/google-oauth-100-user-limit/), [Google support page](https://support.google.com/cloud/answer/7454865)). **(unverified: Google's own page was not read in full.)**
- Exceptions to verification: personal use, dev/test, internal org use ([restricted-scope page](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification)).
- Sensitive verification: "typically takes 3-5 business days"; needs a demo video, a privacy policy on the home-page domain, domain ownership in Search Console, and a published brand ([sensitive-scope page](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification)).
- Restricted verification: "can potentially take several weeks"; reverify and reassess "at least every 12 months" (same restricted page).
- **CASA.** Google ties the assessment to servers: "If you store or transmit restricted scope data on servers, then you need to complete a security assessment." The page does not address apps with no server of their own. An older Google blog advised storing restricted data only on the device to avoid it ([Google Developers Blog](https://developers.googleblog.com/get-smart-about-preparing-your-app-for-oauth-verification/)).
- **Cost.** Sources disagree by two orders of magnitude. Nylas cites "$15,000-$75,000" and "a few weeks to (more commonly) multiple months" ([Nylas](https://www.nylas.com/blog/google-oauth-app-verification/), 2021 page). TAC Security lists $540 per app for a Tier 2 package ([TAC FAQ](https://tacsecurity.com/?p=18721), via search result). I found no Google fee schedule. **(unverified)** Get two assessor quotes before committing.
- **Why CASA probably applies to Perry (inference).** Perry sends mail text to the user's chosen cloud model (OpenAI, Anthropic and so on). That is a transmission of restricted data to a third-party server, even though Perry runs none. Google's Limited Use policy allows transfers "to provide or improve your appropriate access or user-facing features" with user consent ([API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy)). Whether a reviewer reads BYOK as "your server" is a question only Google can answer. One design lever: allow Gmail content into the prompt only when the on-device brain is selected. Ask Google's review team before building it.
- **Testing mode.** Authorisations expire after 7 days in Testing status, per a secondary source ([Unipile](https://www.unipile.com/google-oauth-100-user-limit/)) **(unverified)**.

**Owner identity.** A Google account that owns the Cloud project, plus a verified domain, plus a privacy page. No company is required by Google's pages. CASA assessors may expect a company **(inference)**.

**Refresh and storage.** `access_type=offline` gives a refresh token. Perry sets that already (`App/RemoteIntegrations.swift:856`). Storage is the Keychain (`App/RemoteIntegrations.swift:1045`).

**Rate limits.** Gmail: 6,000 quota units per minute per user per project; `messages.get` costs 20 units, or 60 with `format=full` ([Gmail quota](https://developers.google.com/workspace/gmail/api/reference/quota)).

**Google's own Workspace MCP servers** (Gmail, Drive, Calendar at `*mcp.googleapis.com/mcp/v1`) are in Developer Preview. They need Program membership and a **Web application** client flagged for AI agents ([configure MCP servers](https://developers.google.com/workspace/guides/configure-mcp-servers); [Workspace Updates, 1 May 2026](https://workspaceupdates.googleblog.com/2026/05/agent-tools-and-security-updates-for-workspace-developers.html)). They use the same restricted scopes. They are not a shortcut for a desktop app.

#### 1.2.2 Notion

- **Registration.** Create a *public connection* in the developer portal. Install scope ("Any workspace" or "Selected") "can't be changed after creation." The Authorization URL "populates after a public connection is submitted for review" ([Notion authorization](https://developers.notion.com/docs/authorization)).
- **Secret.** Required. Token and refresh calls use HTTP Basic with client ID and secret. The page does not mention PKCE. Perry already models this as `.basicSecret` (`App/RemoteIntegrations.swift:796`). A Perry-owned Notion app means the secret ships in the binary. Perry is AGPL-3.0 (`PRD.md:188`), so the secret would also be readable in source unless injected at build time. Even then it is extractable from the binary. Notion's policy on this is not documented **(unverified)**.
- **Redirect.** The page documents no rule for custom schemes or localhost. A Composio guide says HTTPS only ([Composio Notion](https://composio.dev/auth/notion)) **(secondary)**. Test custom scheme and loopback at registration. If only HTTPS works, use a static redirect page on Perry's domain that forwards to the custom scheme, or `ASWebAuthenticationSession.Callback.https` with a universal link **(inference; the Callback API is macOS 14.4+ from memory, Apple's page did not load)**.
- **Scopes.** None. Capabilities are set on the connection.
- **Refresh.** Refresh returns a new access and refresh token. Lifetimes are not stated.
- **Rate limit.** About 3 requests per second on non-Business plans; 429 with `Retry-After` ([Notion limits](https://developers.notion.com/reference/request-limits)).
- **Review timeline.** Not documented.
- **Alternative.** Notion hosts an MCP server with OAuth and per-client admin controls ([Notion MCP](https://developers.notion.com/docs/mcp)). Whether third-party clients register dynamically is not stated **(unverified)**. If it works, Perry skips the secret and the review.

#### 1.2.3 Slack

- **PKCE is GA.** Enable `pkce_enabled` in app settings or manifest. It is "one-way": the app becomes a public client ([Slack PKCE](https://docs.slack.dev/authentication/using-pkce); [changelog 2026-03-30](https://docs.slack.dev/changelog/2026/03/30/pkce)).
- **Redirects.** Custom schemes always count as desktop redirects and need PKCE. `http://localhost` counts as desktop only when PKCE is on. Standard redirects must be HTTPS ([installing with OAuth](https://docs.slack.dev/authentication/installing-with-oauth)).
- **Limits of desktop redirects.** No bot scopes. Rotating tokens always. "All refresh tokens issued to your app will expire in 30 days." Whether each refresh resets that clock is not stated **(unverified)**.
- **Perry fit.** Perry already sends `user_scope` for PKCE (`App/RemoteIntegrations.swift:344-346, 1204-1206`). It also asks for `chat:write` at connect time (`:815`). That breaks the read-first promise. Request `chat:write` only on step-up.
- **Distribution.** "Manage Distribution" unlocks a shareable install link ([distribution](https://docs.slack.dev/distribution)). Marketplace listing needs 5 or more active workspaces and a manual review; no turnaround is published ([Marketplace docs](https://docs.slack.dev/slack-marketplace/slack-marketplace-review-guide)).
- **Rate limits.** *Commercially distributed non-Marketplace apps* get `conversations.history` and `conversations.replies` at **1 request per minute, 15 objects** ([Slack changelog](https://docs.slack.dev/changelog/2025/05/29/rate-limit-changes-for-non-marketplace-apps)). Perry's scopes include `channels:history` and `groups:history` (`:810-813`), so this hits the main read path. Whether a free AGPL app counts as "commercially distributed" is unclear **(unverified)**. Ask Slack.
- **Admin approval.** Many workspaces require an admin to approve new apps **(inference)**.
- **Hosted MCP.** Slack's official MCP server (`https://mcp.slack.com/mcp`) went GA 17 February 2026 and appears to skip dynamic registration **(unverified; third-party directories)**.

#### 1.2.4 Linear

- **Public client works.** With PKCE, `client_secret` is "(optional)" and `code_verifier` is required. Refresh with PKCE needs only `client_id` ([Linear OAuth](https://linear.app/developers/oauth-2-0-authentication)).
- **Redirect.** Not specified. Test a custom scheme at registration.
- **Scopes.** `read`, `write`, `issues:create`, `comments:create`, `admin`. Perry requests `read` and `write` together (`App/RemoteIntegrations.swift:830`). Request `read` first.
- **Tokens.** Access tokens last 24 hours; refresh is needed.
- **Rate limit.** 5,000 requests and 2,000,000 complexity points per hour per user ([Linear limits](https://linear.app/developers/rate-limiting)).
- **Review.** None documented.
- **Hosted MCP.** `https://mcp.linear.app/mcp`, OAuth 2.1 with dynamic client registration, plus `/mcp/readonly` ([Linear MCP](https://linear.app/docs/mcp)).

#### 1.2.5 GitHub (not in Perry's catalog today)

- **Device flow** needs no client secret and no redirect. Enable it in the app settings first. Codes expire after 15 minutes; 50 submissions per hour per app ([GitHub OAuth](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps)).
- **Web flow** supports PKCE (`S256` only) but still requires the secret. Loopback redirect may use any port; GitHub advises `127.0.0.1` over `localhost`. Custom schemes are not addressed.
- **Tokens.** Non-expiring by default. Expiring tokens are opt-in (8 hours access, 6 months refresh, rotating).
- **Scopes.** OAuth App scopes like `repo` are coarse. GitHub recommends GitHub Apps with fine-grained permissions (same page).
- **Rate limit.** 5,000 requests per hour for an authenticated user (general knowledge; not fetched in this pass).
- **Owner identity.** A personal account is enough.

#### 1.2.6 Microsoft Graph (not in Perry's catalog today)

- **Registration.** Free, in Entra. Register as a public client. "Public clients ... must not use secrets or certificates when redeeming an authorization code" ([auth code flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow)).
- **Redirect.** `http://localhost` for system-browser apps; the port is not matched. MSAL's `msauth.<bundle>://auth` scheme is the usual macOS alternative **(from memory, not on the fetched page)**.
- **Scopes.** `Mail.Read`, `Calendars.Read`, `Files.Read`, `User.Read`, `offline_access`. User-consentable unless the tenant forbids it.
- **Refresh.** Native refresh tokens have no fixed lifetime. Replace the old refresh token on each use.
- **Publisher verification.** Needs a Microsoft AI Cloud Partner Program account, an Entra work or school tenant, and a matching domain. "No charges." Apps registered with a personal Microsoft account cannot be verified. Where risk-based step-up consent is on, users cannot consent to unverified multitenant apps ([publisher verification](https://learn.microsoft.com/en-us/entra/identity-platform/publisher-verification-overview)).
- **Effect (inference).** Personal Outlook.com accounts work without verification. Work accounts in locked-down tenants will not.

### 1.3 What can ship when

| Wave | Providers | Blocking work | Who must act |
|---|---|---|---|
| A: days | Linear, GitHub device flow, Calendar via EventKit | Register two apps. Add a "Connect" button. No domain needed for Linear or GitHub | Owner registers; code change small |
| A+: days, with caveats | Slack | Register app, enable PKCE, accept 1 req/min risk | Owner |
| B: weeks | Google Calendar plus `drive.file`, Microsoft (unverified publisher first), Notion | Domain, privacy page, demo video, loopback listener, Notion review, bundled Notion secret | Owner plus code |
| C: months | Gmail read, Drive read | Restricted verification, likely CASA, annual reassessment | Owner plus assessor |

### 1.4 Cheaper interim for Gmail

| Option | What it gives | Cost and risk | Verdict |
|---|---|---|---|
| **Bring-your-own client, guided** | Today's path, with a wizard that links each console page and accepts the downloaded `client_secret.json` | Still 6+ steps for the user. Testing-mode tokens expire in 7 days **(unverified)**, so tell users to publish their project to "In production". Personal use is exempt from verification | Keep, as "Advanced" |
| **Mail.app through Automation** | Read mail the user already syncs in Mail, for Gmail, iCloud and Exchange alike. One Automation prompt. `NSAppleEventsUsageDescription` already exists (`project.yml`) | Needs Mail configured. AppleScript search is slow on large boxes. No label API **(inference, untested)** | Best zero-setup fallback |
| **IMAP plus app password** | Works on personal Gmail with 2-Step Verification | Not available on Workspace or Advanced Protection accounts. Google calls app passwords "unnecessary in most cases" ([Google](https://support.google.com/accounts/answer/185833)). The password grants the whole mailbox, not read-only. Needs an IMAP client, which is a new dependency | Reject |
| **Internet Accounts alone** | Nothing. macOS exposes no Google token to apps **(inference)** | n/a | Not an option |
| **Google Workspace MCP** | Official tools | Preview program, Web client type, same restricted scopes | No gain |

Also **EventKit** reads any calendar the user added in Internet Accounts, Google included, behind one Calendar permission **(inference from platform behaviour, untested)**. **Google Drive for Desktop** mounts files under `~/Library/CloudStorage`; Perry's file tools can read normal files there. Docs and Sheets appear as pointer files, so those still need the API **(inference)**.

### 1.5 Brokers versus self-registration

| Broker | What I found | Own OAuth app? | Data path |
|---|---|---|---|
| **Nango** | Free: 10 connections, 10 compute hours, 10 GB. Pay-as-you-go $50 per month plus $0.29 per connection. "Use pre-approved OAuth apps or bring your own" ([pricing](https://www.nango.dev/pricing)). Self-hosting is Enterprise | Yes | Calls and tokens go through Nango |
| **Pipedream Connect** | Free in development. Production price not stated. "Never expose secrets in your client-side code" ([docs](https://pipedream.com/docs/connect)) | Yes | Tokens held by Pipedream; payloads "not stored" per their docs |
| **Composio** | Free tier exists. Prices otherwise from a competitor's comparison ([Composio blog](https://composio.dev/blog/nango-alternatives-ai-agents)) **(unverified)** | Not confirmed | Hosted |
| **Arcade** | Usage-based with a free tier **(unverified)**. Acquired Smithery in August 2026 | Not confirmed | Hosted |
| **Smithery** | Connection service ends **31 October 2026** ([Smithery](https://smithery.ai/future)) | n/a | Do not build on it |
| **Klavis** | Hosted MCP with OAuth. Hobby free, Pro $9.99 per month **(unverified; undated page)** | Not confirmed | Hosted |

**Trade-off.** A broker's *pre-approved* Google or Notion app is the only way Perry could offer Gmail one-click soon. The price:
- Every message and file read goes through a vendor Perry does not control. Perry's page says "on this Mac" (`App/SettingsView.swift:663`: "Connections stay in this Mac’s Keychain"). That sentence becomes false.
- The broker API key must live in the binary, or Perry must run a small backend. Both break the PRD stance (`PRD.md:95` lists "cloud accounts" and "hosted inference" as out of scope; `PRD.md:188` leaves a hosted tier open to revisit).
- Users would see the broker's name on the Google consent screen.
- Perry gains a vendor dependency with its own outages and price changes.

**Recommendation.** Self-register for Waves A and B. Treat a broker as an opt-in "Connect Gmail through [vendor]" for users who accept the data path, and only after the owner makes that call. Do not make it the default.

### 1.6 The generic path: MCP OAuth

`CustomConnectors` accepts a URL and a static bearer secret (`App/CustomConnectors.swift:15-20, 193-194`). It cannot sign in to a hosted MCP server. The MCP spec requires: protected-resource metadata discovery (RFC 9728), PKCE, the `resource` parameter (RFC 8707), and one of Client ID Metadata Documents, pre-registration, or DCR ([spec](https://modelcontextprotocol.io/specification/draft/basic/authorization)). Building that once gives:
- One-click connect to any vendor MCP that supports DCR or CIMD, with no Perry registration and no vendor review of Perry.
- The vendor's own scopes and read-only endpoints (Linear `/mcp/readonly`).
- No secret in the binary.

Limits: tool quality differs per vendor; each tool still needs Perry's approval tiers (`MCPConnector.swift:24-36` carries `readOnlyHint`); and Notion, Slack and GitHub support is unconfirmed.

---

## 2. Part 2: Perry's integration code today

### 2.1 What exists

| Piece | Where | Behaviour |
|---|---|---|
| Catalog | `App/RemoteIntegrations.swift:784-858` | Four definitions: Notion (`.basicSecret`, `:796`), Slack (`.pkce`, `:818`), Linear (`.pkce`, `:832`), Google Workspace (`.pkce`, `:855`). Google is one definition with five scopes (`:844-853`). |
| Auth styles | `:8-20` | `basicSecret`, `formSecret`, `pkce`. `requiresClientSecret` drives the form. |
| Config | `:891-910` | `OAuthConfiguration(clientID, clientSecret, redirectURI, scopes)`. Default redirect `dev.perry.perry:/oauth/callback` (`:892`). |
| Coordinator | `:1161-1341` | `OAuthCoordinator.authorize` builds the URL (`:1197-1224`), runs `ASWebAuthenticationSession` (`:1226`), checks `state` (`:1327`), exchanges the code (`:1330-1339`). PKCE verifier only when style is `.pkce` (`:1195`). |
| Browser session | `:1262` | `prefersEphemeralWebBrowserSession = true`. The user signs in to the provider from scratch every time. This hurts "one click" (see 2.2 item 4). |
| Credential store | `:1042-1087` | `OAuthCredentialStore` actor over `KeychainStore(service: "dev.perry.integrations")` (`:1045`). Account `integration.<id>`. |
| Stored shape | `:970-1010` | `StoredOAuthCredential` saves token, **clientID, clientSecret**, granted scopes together. A legacy decode path sets `clientID: ""` (`:1068`). |
| Refresh | `:1477-1506` | Reads `clientID` and `clientSecret` from the stored credential (`:1484-1491`). Retries once on 401 (`:1525`). |
| Redirect handling | `:1309-1314`, `project.yml:80-84` | Callback must equal the configured scheme, host, path, port. The URL scheme is also registered in `Info.plist`. |
| Disconnect | `:1280-1282` | Deletes the local credential only. No provider-side revoke. |
| UI | `App/IntegrationRow.swift:84-118` | "Set up" opens a form: callback URL text (`:96`), client ID field (`:99`), secret field when required (`:101-104`), "Connect" (`:106`). Copy at `:92`: "This build needs your own OAuth app". |
| Bridge | `App/IntegrationConnections.swift:21-37` | `connect(definition, clientID:, clientSecret:)` passes user input straight into `OAuthConfiguration`. |
| Wiring | `App/AppSubsystems.swift:353-367` | One `OAuthCoordinator`, one `RemoteIntegrationClient`, one `IntegrationConnections`. |
| Settings tab | `App/SettingsView.swift:660-681` | Lists the catalog, then `CustomConnectorsSection`. Onboarding has no connection step (confirmed in R7 section 1.1). |
| Safety | `:438-566`, `:22-67` | Allow-listed read paths and five typed write operations (Notion create, update, append; Slack send; Linear update). Writes are off by default (`RemoteIntegrationPermissionStore`, `:861-889`). |

### 2.2 What must change for bundled client IDs

1. **Per-definition client config.** Add bundled `clientID` (and optional secret) to `RemoteIntegrationDefinition`. Inject from build settings. `project.yml` already does this for `SUFeedURL: "$(PERRY_UPDATE_FEED_URL)"` and `SUPublicEDKey` (`project.yml:72-75`); reuse the pattern. Keep secrets out of the repo.
2. **Connect without input.** `IntegrationConnections.connect` (`:21-37`) should resolve client config from the definition when present. Keep today's signature for "Use my own app".
3. **UI.** Replace the form (`IntegrationRow.swift:90-118`) with a single "Connect" button. Move the form behind "Use my own OAuth app". Change `canConnect` (`:181-185`) accordingly.
4. **Redirect modes.** `OAuthConfiguration.defaultRedirectURI` (`:892`) is one global. Add per-definition redirect kind:
   - *custom scheme* through `ASWebAuthenticationSession` (Slack, Linear, Microsoft if MSAL scheme registered);
   - *loopback* through a short-lived `NWListener` on `127.0.0.1` with a random port, opened in the default browser (Google required, GitHub, Microsoft);
   - *https* through a static page on Perry's domain (Notion if needed).
   The exchange check at `:1309-1314` must accept the loopback port.
5. **Session persistence.** Use a non-ephemeral session for Perry-owned flows so the user's existing Google or Slack browser session works. This is the difference between "click, approve" and "click, type password, approve" **(inference from `:1262`)**.
6. **Secret handling.** `StoredOAuthCredential` persists `clientSecret` (`:973`). For bundled clients store a marker (`bundled`) and resolve the secret at refresh time. Then rotating a bundled client or secret does not strand saved credentials. Refresh would break only for credentials issued under the old client ID.
7. **Staged scopes.**
   - Split `google-workspace` (`:835-857`) into Calendar, Drive and Gmail definitions, or request scopes incrementally. Calendar can ship while Gmail waits.
   - Remove `chat:write` (`:815`) and Linear `write` (`:830`) from first consent. Step up when the user turns on writes (`IntegrationRow.swift:119-129`).
8. **Provider revoke on disconnect** (`:1280-1282`). With Perry-owned apps, a leftover grant stays on the provider side. Add revoke calls **(inference: good practice, not required by any page I read)**.
9. **New definitions.** GitHub (device flow needs a new coordinator branch with no redirect) and Microsoft (loopback). Each needs `quickActions` (`:451-507`) and allow-list rules (`:508-566`).
10. **`iss` check.** If MCP OAuth is added, validate `iss` per the spec's RFC 9207 section.
11. **Test on the remote Mac, not the user's MacBook** (memory: `no-local-tests-while-in-use`). Real provider sign-in needs registered apps, which this task did not create.

### 2.3 Three overlapping systems

| System | Files | Auth | Tool surface | Approval path |
|---|---|---|---|---|
| **A. RemoteIntegrations** | `App/RemoteIntegrations.swift`, `App/IntegrationConnections.swift`, `App/IntegrationRow.swift` | OAuth, Keychain | Typed writes for Do plans through `RemoteIntegrationActionRuntime` (`:1674-1733`), wired in `ForegroundTaskController.swift:608` | Plan approval; `RemoteIntegrationApproval` minted from the plan action (`:1722-1729`) |
| **B. Model tools `integrations.*`** | `Packages/PerryBrain/Sources/PerryBrain/Tools/IntegrationTools.swift:42-60`, `App/Tools/IntegrationBackendAdapter.swift:16-57` | Reuses A's credentials | `list`, `read`, `write` tools. Reads map to A's quick actions only | Host marks writes orange (`IntegrationTools.swift:156`). The adapter then **mints its own approval** with a random `stepID` (`IntegrationBackendAdapter.swift:101-112`) |
| **C. MCP connectors** | `App/CustomConnectors.swift`, `Packages/PerryBrain/Sources/PerryBrain/MCP/MCPConnector.swift`, `MCPServer.swift` | Static bearer or env var, Keychain service `dev.perry.connectors` (`CustomConnectors.swift:41`) | Remote tools bridged as executors; unknown-effect tools default orange (`MCPConnector.swift:39-42`) | Tool-tier approval |

Overlap and gaps:
- A and B both mint `RemoteIntegrationApproval` in separate places. B's comment admits the credential-layer record is synthetic.
- A, B and C each own a connection state and a "Disconnect". The user sees them in different Settings sections.
- C cannot do OAuth; A is hard-coded to four providers. A new provider needs a definition, quick actions, write allow-list and adapter mapping. A hosted MCP server needs only C plus OAuth.
- **Direction (inference).** Keep A for the four providers that need typed, verified writes. Add MCP OAuth to C. Collapse B's approval minting into A's single entry point. Do not add a fourth system.

---

## 3. Part 3: Routines ("Watch & Learn")

Two different things carry the word "routine" in Perry:
- **Watch & Learn routines**: recorded demonstrations, replayed through the typed-plan engine. This is the owner's question.
- **Scheduled Perrys**: a named job on an interval, run by `PerrySchedulerController` (`docs/evidence/phase-9a/scheduled-routine.md`). That is the HeyClicky-style "routine".

### 3.1 Recording

| Step | Code | Behaviour |
|---|---|---|
| Start | `App/StatusMenuController.swift:105-113` ("Watch & Learn" submenu, "Record a demonstration…"); `App/RoutineLibraryController.swift:95-133` | Opens the review window in recording phase, starts the recorder, speaks "Recording." |
| Listen | `App/DemonstrationRecorder.swift:51-70` | Global and local `NSEvent` monitors for `leftMouseDown` and `keyDown` only |
| Bounds | `:11, :34-35` | 60 events; 600 seconds; warning at 30 seconds left |
| Click capture | `:116-123, :149-160` | On each click, take a fresh AX observation through a Cua worker (`RoutineLibraryController.swift:214-229`). Pick the smallest *actionable* element containing the point. Store `RoutineTarget(role, label, subrole)`. Clicks on nothing actionable are dropped. |
| Key capture | `:134-144` | Return, tab, escape, space, delete and arrows become key presses (`:135`, `:162`). Plain characters append to the last clicked target. Any chord with Cmd, Ctrl, Option or Fn is **dropped** (`:139-140`). |
| Secrets | `:122, :141` | Typing is dropped when the *last click* hit a non-ordinary (secure or unknown) field. |
| App | `:54` | One bundle ID, read at start |

**Not captured:** right-click, drag, scroll, double-click (the `doubleClick` event type exists in `RecordedEvent` but the recorder never emits it), time between steps, window or tab identity, anything about a second app, screenshots.

**Gaps I can see in the code (inference, not run):**
- *Tab into a password field.* Tab records as a key press, but `lastClickTarget` and `lastClickSensitive` stay on the previous field (`:122`, `:141`). Characters typed after tabbing into a secure field attach to the earlier, ordinary target and are stored. I did not run this.
- *Input Monitoring.* Global key monitors need Input Monitoring on current macOS. The shortcut code comments that without the grant the fallback "only sees Perry's own events" (`App/PushToTalkController.swift:58-61`). The recorder does not check or request the grant, so key events from other apps may silently never arrive.
- *Doc mismatch.* `docs/capabilities.md:77-79` says the recorder does not capture "keystrokes' values". It does. Typed text is stored as `.literal` (`LearnedRoutine.swift:248`) and written into the `.md` file. Only the review toggle (`RoutineReviewWindow.swift:146`, `RoutineLibraryController.swift:160-175`) swaps it for a parameter.

### 3.2 Generalisation

- **Local, deterministic** (`RoutineInference.infer`, `LearnedRoutine.swift:240-283`): a click that focuses a field folds into the following type step; consecutive typing on one target merges. Nothing else is compressed.
- **Optional provider polish** (`RoutineSynthesis`, `LearnedRoutine.swift:424-`, wired at `RoutineLibraryController.swift:149`): renames the routine and rewrites step summaries. The prompt carries roles, labels and bundle ID, never typed values or screenshots. The reply must match a strict schema or the local draft stands.
- **Parameters** are manual: the user toggles "Ask me for this text each time" on a typed step (`RoutineReviewWindow.swift:146`). One slot per typed step; up to 20 (`LearnedRoutine.swift:9`).
- **No** loops, conditions, variables across steps, or intent inference. "Generalisation" here means "this typed string becomes a prompt".
- **Review before save** is enforced: nothing persists until the user names it and clicks Save (`RoutineLibraryController.swift:160-185`).
- **Storage:** one Markdown file with a fenced JSON block per routine, 64 KB and 50 steps maximum, strict key validation on import (`LearnedRoutine.swift:289-345`, store at `:345`). Imports cannot claim `tested` (`:395`).

### 3.3 Replay

1. Menu or Home "Run now" calls `RoutineLibraryController.run` (`:50-60`). Parameters open a fill form first.
2. `ForegroundTaskController.beginRoutine` (`App/ForegroundTaskController.swift:325-351`) refuses if a task is active, runs preflight, takes a foreground worker.
3. `runRoutineOperation` (`:353-396`) captures screen context, then takes **one** fresh AX observation of the routine's app (`:373`).
4. `RoutineReplay.plan` (`Packages/PerryGuide/Sources/PerryGuide/RoutineReplay.swift:36-120`) turns every step into an `ExecutableAction`:
   - target must match exactly one element by role, label and subrole (`:124-141`); zero is "no longer on screen", two or more is "ambiguous";
   - manual steps become `askUser` pauses (`:60-72`);
   - the plan needs plan-level approval (`approvalRequirement: .plan`, `:107`).
5. `executePreparedPlan` (`ForegroundTaskController.swift:586-`) validates the plan, then the supervisor runs it step by step with a verifier.
6. Verification (`App/CompositeActionVerifier.swift:82-100`): typed text must appear in the window's AX labels; click and key steps must make the window screenshot hash differ from the baseline.

### 3.4 How reliable is it likely to be?

No measured success rate exists in the repo. Evidence is 21 unit tests (`LearnedRoutineTests.swift`) and a scripted demo (`docs/demo-script.md:100-111`, "Beat 7"). `docs/evidence/` has no live Watch & Learn run. I did not run the app. The points below come from reading the code.

| Issue | Evidence | Effect |
|---|---|---|
| **All targets resolve against one early snapshot** | `RoutineReplay.swift:57-110` loops every step over the single `observation.snapshot.elements`; resolution at `:124` | Step N that targets a menu item, sheet, popover, next page or rename field that appears only after step N-1 fails at plan time with "step N's control is no longer on screen". Nothing runs. Only single-screen flows are safe. The Finder rename in the demo script presses Return, then types into the rename field. That field may not exist in the first snapshot **(inference; needs a live test)**. |
| **Exact label match** | `RoutineReplay.swift:124-141` | Labels with changing text (file names, "Inbox (3)", document titles) stop matching. Unlabelled controls match every element of their role, so they are "ambiguous". |
| **Weak click verification** | The baseline hash is built once from the pre-run screenshot (`RoutineReplay.swift:143-`). The verifier compares each step to it (`CompositeActionVerifier.swift:89-96`) | After step 1 changes the window, steps 2 to N pass as long as the window still differs from the start. It proves "the window changed", not "this step worked". |
| **Typed-text check is loose** | `CompositeActionVerifier.swift:82-88` | Passes if the string appears anywhere in the AX tree. |
| **No waits** | Waits are skipped (`RoutineReplay.swift:59`), and the recorder never emits them | Slow pages and animations rely on the verifier alone. |
| **One app** | `RoutineReplay.swift:42`; recorder reads one bundle ID | No copy-from-A-paste-into-B routines. |
| **Shortcuts lost** | `DemonstrationRecorder.swift:139-140` | Cmd-C, Cmd-V, Cmd-S, Cmd-N are not recorded. Many real workflows depend on them. |
| **Browsers** | AX trees for web content are large and often unlabelled **(inference)** | Web routines will often be ambiguous. |
| **No learning loop** | `.tested` provenance is never set by local code (`grep` finds only the import downgrade, `LearnedRoutine.swift:395`, and a Home check, `HomeView.swift:239`) | Perry never records "this routine worked 5 times". The Home card always says "Perry checks the current app before each step." |
| **No undo for GUI steps** | `docs/follower-test-card.md:66-68` | A wrong click cannot be reversed. |

What works well: Perry re-reads the screen and refuses to guess. It never replays coordinates. It pauses for manual steps. It stops on a miss rather than clicking blind. A failed replay is safe, not wrong. The design matches the honest line in `docs/capabilities.md:80-83`.

**Plain summary.** Replay is likely reliable for a one-window sequence of clicks and typing into stable, uniquely labelled controls. It is likely to fail early on anything with a menu, a dialog, a new page or dynamic labels. When it fails, it fails safely and says why.

### 3.5 Comparison

| Product | What it is | Capture | Replay | Source |
|---|---|---|---|---|
| **HeyClicky routines** | *Not* demonstration. Scheduled repeat prompts, such as "give me a daily briefing". Created by asking. Pause, resume, run or delete from the profile or Settings. Three failures in a row pause the routine. Missed runs run once after wake | Natural language | Agent re-runs the prompt on the Mac while the app is open | [changelog v1.0.49-1.1.1](https://heyclicky.com/changelog) |
| **HeyClicky walkthroughs** | Guides the user, up to 15 steps, detects the user's click | n/a | Not hands-free | same |
| **Perry scheduled Perrys** | HeyClicky-equivalent. Interval schedule, bound thread | Natural language | Agent loop | `docs/evidence/phase-9a/scheduled-routine.md` |
| **Perry Watch & Learn** | Demonstration of one app window | Clicks, keys, AX element under each click | Typed plan, AX re-resolution, plan approval | sections 3.1-3.4 |
| **Claude "Record a Skill"** (Cowork) | Records screen, clicks, keystrokes and narration. Saves a Skill. Announced 21 July 2026, paid plans, desktop | Screen plus narration | Representation not published | [Digital Applied](https://www.digitalapplied.com/blog/claude-record-a-skill-train-agents-by-demonstration-2026) **(secondary)** |
| **OpenAI Codex "show it once"** | Records a task, produces a skill describing data locations, steps and preferences. Reported 19 June 2026 | Screen recording or live session | Computer use, browser use or plugins | [ExplainX](https://explainx.ai/blog/openai-codex-teach-skill-by-showing-recording-2026) **(secondary)** |
| **Microsoft Skill Recorder** | Open-source. Screen snapshots, windows, URLs, optional narration. Output is a `SKILL.md` you can edit. Analysis runs in Copilot's cloud | Screen plus narration | Prefers native tools over UI replay | [Menon Lab](https://themenonlab.blog/blog/microsoft-skill-recorder-teach-agents-by-demonstration) **(secondary)** |

**Reading across (inference).** The 2026 pattern is *demonstration to intent*: record, let a model write the procedure in words, replay through whatever tool is best (API, CLI, browser, UI). Perry records *low-level actions* and replays *them*. Its strengths are privacy (local, no screen video, no cloud analysis), review before save, and verified steps. Its weakness is brittleness: no narration, no model-written intent, no fallback to a better tool, and one-snapshot planning. Perry could keep its local-first rule and still add one optional narration line ("what are you trying to get done?") so the saved routine holds an intent string for the model to repair a failed step. That is a design option, not a finding.

### 3.6 Fix before promoting it

Cheap and local, in order of effect on onboarding honesty:
1. **Replan per step.** Resolve each target against a fresh observation just before it runs. This one change removes the "later screen" failure. (`RoutineReplay.plan` is pure; the supervisor already re-observes between actions for general plans — check before building.)
2. **Per-step baseline** for click verification, not the pre-run hash.
3. **Record Cmd chords** as named key presses with modifiers, or mark such routines "includes a shortcut I could not record".
4. **Carry the sensitivity flag** across Tab and Return key presses.
5. **Ask for Input Monitoring** before recording, or say recording will miss typing.
6. **Default typed text to "ask each time"** and fix `docs/capabilities.md:77-79`.
7. **Set `tested`** after a verified local run and show "worked N times".
8. **Run the Beat 7 demo live** on the test Mac and save the result to `docs/evidence/`.

### 3.7 Where it should appear in onboarding

R7 proposes the beat order Hello, Brain, Access, Shortcuts, Interview, Apps, First goal. The code today has six beats (`OnboardingDirector.swift:8`).

**Place it after the first goal, never inside setup.**
- The feature needs Accessibility, Screen Recording and a working brain already. By then they exist.
- A new user has no routine in mind yet. After Perry completes one real task, "do that again later" is natural.
- Setup is already long (R7 targets about 125 seconds). A recording beat inside it would double the time.
- It stays optional and skippable. It must not block the finale.

**Trigger options, best first:**
1. After the first completed Do task that used a GUI app: a small card in the notch, "Want me to learn this one so you can run it again?" This is the cheapest path, because Perry already has the task's steps. **(Not built: the typed plan from a normal Do task is not converted to a routine today. The dead comment at `App/AppController.swift:477` — "Onboarding's post-demo offer: starts a Watch & Learn recording once" — shows an earlier offer existed and was removed.)**
2. A one-line row in the finale: "Later: show me something you do often."
3. A first-week nudge in Home when the user repeats a similar request twice **(inference; needs a repeat detector)**.

### 3.8 Copy, recording UX, aftermath

The owner's words: "hey show me a routine and i can do that for you". Use that voice. Keep sentences short.

**Offer card (notch, after first goal):**
- Title: **"Show me one thing you do often."**
- Body: **"Do it once while I watch. I will write down the steps. You check them before I save anything."**
- Buttons: **"Show me"** · **"Not now"**
- Small print, shown before recording starts: **"Works best for steps inside one app window. I cannot see passwords. I may not copy shortcuts like ⌘C yet."**

**Before recording (one screen, two checks):**
- Perry confirms Accessibility, Screen Recording and Input Monitoring. If Input Monitoring is missing: **"I need one more permission to see your typing."** with the same drag helper R2 proposes.
- Perry asks: **"Which app will you use?"** and shows the frontmost app. One app only, said plainly.

**Recording UX (in the notch):**
- The notch pill turns to a recording state: a red dot, the step count ("6 steps"), and a **"Done"** button. It never covers the app. The counter already exists as `reviewState.eventCount` (`RoutineLibraryController.swift:114`).
- Each captured click shows a brief ring on the control Perry recognised. A click Perry could not recognise shows no ring. That tells the user a step was lost *while* they can still repeat it.
- At 30 seconds before the 10-minute limit: **"Recording stops in 30 seconds."** (this exists: `RoutineLibraryController.swift:116-118`).
- Esc twice cancels and discards. Nothing saves.

**Review (existing window, plain words):**
- Heading: **"Check what I learned."** Each step is one line. Steps Perry could not recognise are listed as **"You do this one"**.
- Typed text defaults to **"Ask me each time"** (see 3.6 item 6).
- Primary: **"Save routine"**. Secondary: **"Try it now"**.

**Afterwards:**
- First run is a *rehearsal*: Perry shows the plan card, the user approves, and Perry runs it with the step list visible, one line lighting up at a time. The plan approval already exists (`RoutineReplay.swift:97`).
- Success text: **"Done. That worked. I will remember it."** Then set `tested` and show **"Worked 1 time"** in Home.
- Failure text, always with the step: **"I stopped at step 3. I could not find 'Export' on screen. Do this one, then tap Continue."** This matches the existing error strings (`RoutineReplay.swift:22-27`).
- Where it lives: Home sidebar routines (exists) and the notch rail. Run by voice: "run [name]".

**Honesty rules for this beat:**
- Do not say "I can do anything you show me." Say "steps inside one app window."
- Do not claim it always works. Say "If the screen changes, I will stop and tell you."
- Do not show a number for success until Perry has measured one.
- Do not promote import/export of routines in onboarding.

**What the user sees by day two (inference, depends on 3.6):** a saved routine in Home with its run count, a one-tap "Run" in the notch, and, after three failures in a row, a pause with a reason, copied from HeyClicky's rule ([changelog v1.0.50](https://heyclicky.com/changelog)).

---

## 4. Open questions and what I could not verify

1. Does a free AGPL app count as "commercially distributed" for Slack's 1 request per minute limit?
2. Does Google treat a BYOK cloud-model call as "your server" for CASA? Ask Google's review team.
3. CASA price and time for a no-server Mac app. Two quotes needed. Sources conflict from $540 to $75,000.
4. Does Notion accept a custom-scheme or loopback redirect, and does it allow a shipped secret?
5. Does Linear accept a custom-scheme redirect?
6. Do Notion, Slack and GitHub hosted MCP servers accept third-party clients without pre-registration?
7. Slack: does each refresh reset the 30-day refresh-token life?
8. Google Testing-mode token life (7 days) from a secondary source only.
9. Calendar and Docs/Sheets scope classes: Google's pages did not show them to my fetcher.
10. Mail.app and EventKit interim paths are reasoned from platform behaviour. A 30-minute spike on the test Mac would confirm them.
11. Watch & Learn: no live run. Items marked inference in section 3.4 need a test on the remote Mac (per the memory note, not the user's MacBook).
12. Secondary sources for competitor features (Claude, Codex, Microsoft). Replace with the vendors' own pages before quoting externally.

## 5. Sources

Google: [native-app OAuth](https://developers.google.com/identity/protocols/oauth2/native-app) · [restricted-scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification) · [sensitive-scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification) · [Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes) · [Drive scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth) · [Gmail quota](https://developers.google.com/workspace/gmail/api/reference/quota) · [API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy) · [Workspace MCP](https://developers.google.com/workspace/guides/configure-mcp-servers) · [Workspace Updates May 2026](https://workspaceupdates.googleblog.com/2026/05/agent-tools-and-security-updates-for-workspace-developers.html) · [app passwords](https://support.google.com/accounts/answer/185833) · [Nylas on verification](https://www.nylas.com/blog/google-oauth-app-verification/) · [Unipile on the 100-user cap](https://www.unipile.com/google-oauth-100-user-limit/)
Notion: [authorization](https://developers.notion.com/docs/authorization) · [request limits](https://developers.notion.com/reference/request-limits) · [MCP](https://developers.notion.com/docs/mcp)
Slack: [PKCE](https://docs.slack.dev/authentication/using-pkce) · [OAuth install](https://docs.slack.dev/authentication/installing-with-oauth) · [rate-limit change](https://docs.slack.dev/changelog/2025/05/29/rate-limit-changes-for-non-marketplace-apps) · [distribution](https://docs.slack.dev/distribution) · [Marketplace review](https://docs.slack.dev/slack-marketplace/slack-marketplace-review-guide)
Linear: [OAuth](https://linear.app/developers/oauth-2-0-authentication) · [rate limits](https://linear.app/developers/rate-limiting) · [MCP](https://linear.app/docs/mcp)
GitHub: [authorizing OAuth apps](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps)
Microsoft: [auth code flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow) · [publisher verification](https://learn.microsoft.com/en-us/entra/identity-platform/publisher-verification-overview)
MCP: [authorization spec](https://modelcontextprotocol.io/specification/draft/basic/authorization)
Brokers: [Nango pricing](https://www.nango.dev/pricing) · [Pipedream Connect](https://pipedream.com/docs/connect) · [Smithery shutdown](https://smithery.ai/future)
Routines: [HeyClicky changelog](https://heyclicky.com/changelog) · [Claude Record a Skill](https://www.digitalapplied.com/blog/claude-record-a-skill-train-agents-by-demonstration-2026) · [Codex teach by showing](https://explainx.ai/blog/openai-codex-teach-skill-by-showing-recording-2026) · [Microsoft Skill Recorder](https://themenonlab.blog/blog/microsoft-skill-recorder-teach-agents-by-demonstration)
Repo: `docs/research/2026-10-25/r7-onboarding-settings.md`, `docs/research/2026-10-25/r1-heyclicky-teardown.md`, `docs/capabilities.md`, `docs/demo-script.md`, `docs/follower-test-card.md`, `PRD.md`.
