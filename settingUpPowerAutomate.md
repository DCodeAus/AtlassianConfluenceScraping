# Setting Up Power Automate for SharePoint Automation: A First-Time Guide

Real SharePoint page automation (the Microsoft Graph API route) needs an Entra ID app registration, which needs admin rights or an admin's one-time consent - not something every account can get. Power Automate's own SharePoint connector runs under your normal signed-in permissions instead of a separate app registration, so it's worth trying as a way around that wall. Nothing in this guide has been confirmed working against a real tenant yet - this is "how to find out," not a guaranteed fix.

## What you need before starting

1. **A Microsoft 365 account with access to Power Automate.** This is usually already included if you have Microsoft 365 through work - no separate purchase needed for the basic flows this guide uses.
2. **Edit access to the SharePoint site** you want to eventually create pages on - the same access you already use browsing it normally.
3. **Patience for Part 3.** Parts 1 and 2 below are quick and safe. Part 3 (actually creating a page) is genuinely fiddly and may take some back-and-forth - budget time for it, don't expect it to work first try.

---

## Part 1: Create a flow and test the connection

This is the actual test of whether this whole approach is even possible for you - if you get blocked here, everything past this point is moot.

### Step 1: Go to Power Automate

Open `make.powerautomate.com` in a browser and sign in with your normal work account. No install needed, it's entirely web-based.

### Step 2: Create a new flow

1. Click **Create** in the left-hand menu.
2. Choose **Instant cloud flow**.
3. Give it a name (e.g. "SharePoint test"), then pick **Manually trigger a flow** as the trigger.
4. Click **Create**.

This gives you a flow with just one step (the manual trigger) that you run on demand by clicking a button - nothing runs automatically yet.

### Step 3: Add the SharePoint action

1. Click **+ New step**.
2. In the search box, type **SharePoint**.
3. From the list of SharePoint actions, pick **Send an HTTP request to SharePoint**. (Not "Get items," not "Create item" - this specific one, since it's the one that lets you call SharePoint's own REST API directly.)

### Step 4: The actual test - signing in

The first time you add this action, it'll ask you to create a **connection** - sign in with your normal work account the same way you would to open SharePoint in a browser.

**This is the real test.** Watch what happens:

- **If it connects cleanly** - no extra prompts, no warnings - you're through the gate that blocks the Entra ID app registration route. Move on to Part 2 below.
- **If you see a "needs admin approval" or similar screen** - this path is blocked the same way the Entra ID route was. See Troubleshooting below.

### Step 5: Fill in a harmless test call

Once connected, fill in the action's fields with something read-only, so this first real test can't accidentally change anything:

| Field | Value |
|---|---|
| Site Address | Your SharePoint site's URL |
| Method | `GET` |
| Uri | `_api/web/title` |

### Step 6: Run it

1. Save the flow (top right).
2. Click **Test** → **Manually** → **Test**, then trigger it (there'll be a "Run flow" button once it's waiting).
3. Once it finishes, click into the run's details and look at what the **Send an HTTP request to SharePoint** step actually returned.

**If it comes back with your site's real title** (not an error), the connector genuinely works under your identity - real progress. If it returns a permission error instead, note the exact error message, that's useful for figuring out what's actually blocked.

---

## Part 2: Confirm it's not a fluke

Before trusting this, try one more read-only call against a different endpoint, just to make sure Part 1 wasn't a one-off:

| Field | Value |
|---|---|
| Site Address | Same site URL |
| Method | `GET` |
| Uri | `_api/web/lists?$filter=Title eq 'Site Pages'` |

Run it the same way. If this also comes back with real data (not an error) about your site's Site Pages library, you're on solid ground to attempt Part 3.

---

## Part 3: Try actually creating a page (advanced, expect trial and error)

Power Automate's SharePoint connector has no built-in "create a modern page" action, so this still goes through **Send an HTTP request to SharePoint**, calling SharePoint's REST API directly, in two separate calls.

### Step 1: Create the underlying page file

Add another **Send an HTTP request to SharePoint** step, with:

- **Site Address**: your site's URL
- **Method**: `POST`
- **Uri**:
  ```
  _api/web/getfolderbyserverrelativeurl('/SitePages')/files/addusingpath(decodedurl='@a1',overwrite=true)?@a1='TestPage.aspx'
  ```

Run it on a **test page name you don't mind creating and deleting** - "TestPage" is fine for now. If this succeeds, you've just created a real (empty) page file in your Site Pages library.

### Step 2: Set its title and content

This is the fiddly part. You need to update the matching item in the "Site Pages" list with fields including `Title`, `PageLayoutType`, and `CanvasContent1` (SharePoint's own JSON format describing the page's web parts - not something to guess at, it needs to match what SharePoint itself expects).

This step needs real trial and error against your own tenant to get right - there isn't a copy-paste body that's guaranteed to work here. Two ways to figure out the right shape:

- Create a normal page by hand in SharePoint's own UI first, then use `Send an HTTP request to SharePoint` with a `GET` to read that page's list item back (`_api/web/lists/getbytitle('Site Pages')/items` filtered to that page) - seeing a real, working `CanvasContent1` value gives you something concrete to model the automated version on.
- Search Microsoft's own Graph/SharePoint REST documentation for "CanvasContent1" for the current expected format, since this has changed between SharePoint versions before.

### Step 3: Clean up your test page

Once you're done experimenting, delete the test page from SharePoint's own UI (or via another HTTP request to the same file, with `Method` `DELETE`) so it doesn't linger.

---

## Troubleshooting

**"Needs admin approval" at Step 4 of Part 1**
This path's blocked the same way the Entra ID route was. Whoever administers your Microsoft 365 tenant would need to approve the Power Automate connector's access, which may or may not be a smaller ask than the original Entra ID app registration - worth asking, since Power Automate is often already broadly used and pre-approved in a tenant even when custom app registrations aren't.

**Part 1 connects, but Part 3's Step 1 fails with a permission error**
Reading (`GET`) and writing (`POST`) can be gated separately - some accounts have read access to more than they have write access to. Check with whoever manages the site whether you actually have "Contribute" or higher permissions there, not just "Read."

**`CanvasContent1` comes out looking nothing like a real page when you check it in SharePoint**
Expected on a first attempt - see Part 3, Step 2's suggestion to read a real page's content back first as a model, rather than guessing at the format from scratch.

**None of this seems worth the effort**
That's a completely reasonable conclusion. The `confluence_sharepoint_paste` copy-paste workflow already documented in the main README works today, with no tenant-specific fiddling - Power Automate is only worth pursuing if you're migrating enough pages that automating page creation specifically would save real time over that.

---

## Quick reference

| Task | Where |
|---|---|
| Create a flow | `make.powerautomate.com` → Create → Instant cloud flow |
| The actual gate-test | Adding a connection to "Send an HTTP request to SharePoint" |
| Safe read-only test | `GET` to `_api/web/title` |
| Create a page file | `POST` to `_api/web/getfolderbyserverrelativeurl('/SitePages')/files/addusingpath(...)` |
| Set a page's content | Update the matching "Site Pages" list item's `CanvasContent1` field |
