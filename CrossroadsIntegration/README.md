# CrossroadsIntegration

Unofficial PowerShell integration module for the [Gravitate Crossroads Integration API](https://docs.gravitate.energy/docs/crossroads-api/index.html). CrossroadsClient owns HTTP. This module owns source adapters, sequencing, pending requests, and receipts. It is not affiliated with Gravitate or the TMW vendor.

## Feed entry points

A feed's whole `job.ps1` is an import and one call. Each call runs in the settings file's folder,
so the log, cache and state land there. Any value written as `env:NAME` is read from that
environment variable, so the committed file holds names, never secrets. A missing required value
stops the run before it does anything, naming the value.

```powershell
Import-Module CrossroadsIntegration
Invoke-CrossroadsOrders "$PSScriptRoot/settings.json"     # or Invoke-CrossroadsDocuments
```

`Invoke-CrossroadsOrders` receives TMW orders and delivers them, one cache per bill-to (`cache/<billto>`
by default, or one shared folder named by `cache`). It logs `Start`, `Get Data: <billto>`, `Use Data`,
`Show Results` and `End` to `yyyyMMdd.log`, and cleans up with `keepdays` and `purgefiles`.

```json
{
  "keepdays": 10, "purgefiles": "*.log",
  "base_url": "https://example/api", "tenant": "ORIGIN", "destination_tenant": "DEST",
  "origin_instance": "optional",
  "division": "DIV", "billtos": ["BILLTO"],
  "client_id": "env:CROSSROADS_CLIENT_ID", "client_secret": "env:CROSSROADS_CLIENT_SECRET",
  "connection_string": "env:CONNECTION_STRING"
}
```

`Invoke-CrossroadsDocuments` reads BOL documents with the feed's `get-data.sql` and delivers them
through `Send-CrossroadsDocuments`. Every row must be in `scope`, or nothing goes. The portal login
happens once, on the first document that needs it. Delivery state is written to the feed's
repository through the GitHub contents API as it happens, so a run that dies midway still leaves its
record. `out/delivery.json` holds the run report.

```json
{
  "keepdays": 10, "purgefiles": "*.log",
  "base_url": "https://example/api", "tenant": "ORIGIN", "destination_tenant": "DEST", "destination_instance": "INSTANCE",
  "client_id": "env:CROSSROADS_CLIENT_ID", "client_secret": "env:CROSSROADS_CLIENT_SECRET",
  "connection_string": "env:EBE_CONNECTION_STRING",
  "scope": { "billtos": ["BILLTO"], "division": "DIV" },
  "ebe": { "base_url": "https://host/ships5web/", "username": "reader", "password": "env:EBE_READER_PASSWORD" },
  "state": { "repository": "env:GITHUB_REPOSITORY", "token": "env:GH_TOKEN", "issue": 1 },
  "max_uploads": 0, "max_documents": 2000, "budget_seconds": 480, "keep_days": 14
}
```

`max_uploads` 0 means no count limit. `prior_attempts` names a folder of earlier attempt records to
honor, and `read_legacy_state` reads the older state layout. `"dry_run": true` reads and plans, and
uploads nothing. It needs neither `ebe` nor `state`.

## Source

`Receive-CrossroadsTMWData` owns cache cleanup, cursor lookup, source retrieval, persistent staging and cursor advancement. It does not send HTTP requests. It returns newly staged local holds as result rows; normal queued requests are reported by Send. An empty source leaves the cursor and retained pending work intact.

```powershell
$delivery = @{ BaseUrl = $baseUrl; Tenant = $tenant; DestinationTenant = $destinationTenant }
$results = @(Receive-CrossroadsTMWData -BillTo $billto -Division $division -ConnectionString $connectionString @delivery)
$results += @(Send-CrossroadsDelivery -ClientId $clientId -ClientSecret $clientSecret @delivery)
$results | Sort-Object state,order_number,kind | Format-Table order_number,kind,http,state,status,error
```

Receive uses the cursor minus five minutes unless `-From` is supplied. In the bundled SQL batch, a missing `-Through` becomes the database's `getdate()` once, and a missing `-From` becomes 55 minutes before that upper bound. This uses one database call, not a separate clock query. Both dates can be overridden. Custom SQL receives nullable `From`/`Through` parameters and must resolve defaults itself, or callers must supply explicit dates. Only a successfully staged nonempty read advances the cursor, using the maximum source update timestamp. No-data runs must still call Send.

The read-only getter never reads or writes a cursor. Its omitted date parameters use the same SQL defaults. For manual control or a dry run, use the lower-level commands below.

`Get-CrossroadsTMWData` returns complete request envelopes from SQL. `Get-Source.sql` captures source rows once; `Get-Requests.sql` groups and prepares the payloads in the same batch. Billto, optional division, and date range are SQL parameters. Override `-SqlFile` with one or more SQL files returning the same envelope contract. `Get-CrossroadsSqlData` also accepts any one-column SQL JSON query directly. Other systems can build these envelopes without the TMW adapter.

```powershell
Install-Module CrossroadsIntegration
Import-Module CrossroadsIntegration
$orders = @(Get-CrossroadsTMWData -BillTo $billto -Division $division -From $from -Through $through -ConnectionString $connectionString)
$delivery = @{ Tenant = $tenant; DestinationTenant = $destinationTenant }
Initialize-CrossroadsDelivery
$staged = @(Add-CrossroadsDelivery -Orders $orders -BaseUrl $baseUrl -Persist $true @delivery)
$results = @(Send-CrossroadsDelivery -BaseUrl $baseUrl -ClientId $clientId -ClientSecret $clientSecret @delivery)
```

The example stages and sends. Use `$false` on Add-CrossroadsDelivery and omit Send-CrossroadsDelivery for a dry run. Credentials and URL are caller inputs; no customer configuration belongs in this folder.

`Send-CrossroadsDelivery -OriginInstance 'source-system'` supplies the optional
source-instance header on order writes and creation lookups. Omit it to retain
server-side instance selection; explicitly blank values fail before I/O. Keep
each feed/cache on one fixed source instance. This parameter does not introduce
multi-instance cache partitioning or change existing receipt identities.

Request projection materializes parsed source and eligible rows into indexed session-local temporary tables. These are discarded when the parameterized command ends; no permanent schema or server settings are changed. SQL access must permit local temporary tables in tempdb.

The included adapter reads a [Trimble TMW.Suite](https://transportation.trimble.com/en/solutions/transportation-management/tmw-suite-tms) fuel-hauling database directly through SQL; it does not call a Trimble API. It assumes Eastern database event times and converts outbound times to UTC in SQL. Source `updated_date` and cursor remain database-local for filtering. It reads orderheader, stops, freightdetail, company, commodity and referencenumber. It uses LLD/LUL stops, freight-linked BOLs and commodity classes 100/200 for net-volume selection. Verify these assumptions against your installation before enabling writes. Supply a reviewed `-SqlFile` override for another timezone, schema or business convention; the transport does not require this adapter.

Create volumes retain half-even integer rounding. BOL and drop quantities allow fractions per the API schema. SQL uses decimals to preserve source precision during JSON transport; the TMW adapter then uses the standard JSON serializer once to remove padding (`7900.0`, `100.1`). It does not round quantities to a fixed number of places. Numeric fixtures compare actual outgoing text with the previous converter.

## Delivery

Each complete envelope contains `order_number`, `updated_date`, `progress`, `hold`, and a `requests` array of `kind`, `path`, `message_key`, and `payload_json`. The payload is finished JSON text, not an object to rebuild. Include every current request for an order: staging supersedes obsolete pending messages. Do not feed partial status-only envelopes into delivery.

Supply one latest snapshot per order in each batch. Add rejects repeated order numbers before staging changes. A fresh `synced` create currently covers the accompanying update; the adapter must put all of that update's relevant fields in its create. An `accepted` create or duplicate-create reconciliation does not skip the update.

Dependent requests wait for a create handoff or confirmed Crossroads order existence for the same base URL, tenant pair, and order, not successful downstream synchronization. A `synced` or `accepted` create receipt establishes the prerequisite immediately, allowing updates and subsequent events in the same send pass without a lookup. Otherwise, stranded work uses a read-only `/v1/order/get` lookup with a flat `order_number`. A successful lookup with a nonblank Crossroads `_id`, matching origin order number, and matching source/destination tenant names in `routing` establishes existence even when aggregate status is `error` or `pending` and no destination number exists. A conflicting destination-origin identity, failed lookup, parse error, or missing existence evidence does not release the gate. Older fully synced readback shapes remain accepted; any provided routing must match.

Readback proof is retained as `kind=create`, `message_key=creation_confirmation`, with `status=exists` when only Crossroads existence is verified. It records GET provenance and `destination_synced=false`; it is not a claim of destination recovery. Fully synced proof retains `status=synced`. A duplicate alone or empty create acknowledgment is insufficient. Failed confirmation produces one `waiting_for_create` row without dependent writes. Actual request acknowledgments continue to drive update/detail/completion prerequisites; aggregate order status does not override those acknowledgments. A sent completion request is not independent confirmation that the destination order completed.

A cancellation is a local no-op when a fresh lookup on its configured URL and tenant pair returns HTTP404 with the exact parsed detail `Order not found for number: <requested order number>` and no conflicting order/route data. It becomes `sent/not_required`, with `not_required_reason=order_not_found` and the lookup evidence in `creation_check.not_found`. No cancellation is sent, no dispatch attempt is added, and no creation proof is manufactured. Prior request response/attempt evidence is preserved; the result's HTTP field is empty because this pass made no cancellation request. The receipt suppresses an identical cancellation during the normal two-day terminal TTL, then expires. A later restaged cancellation gets a fresh lookup. Generic404s, wrong-order messages, empty/malformed bodies, auth/server failures, and old cached lookup evidence do not qualify. Other request kinds still wait for creation; orders that exist follow normal cancellation delivery.

BOL, drop and status requests record their snapshot's update hash and wait for its latest sent receipt. Completion also requires its BOL/drop hashes. An unaccepted supply change holds dependent writes, while an unaccepted detail does not block an independent detail. Required receipts survive cleanup only while dependent work waits. A corrected snapshot refreshes dependencies even when a dependent payload is unchanged. Older pending details adopt a visible update prerequisite; older completions without dependency metadata wait for a fresh source snapshot. A fresh create covering the update counts as a sent, not-required update.

Delivery finishes at Crossroads application acknowledgment, not downstream processing success. For create, update, BOL, drop, status and cancellation requests, a parsed 2xx response with a string status of `error`, `rejected`, `pending`, `requested`, `origin_mapped`, `master_mapped`, `destination_mapped` or `canceled` counts as `state=sent`, `status=accepted`. These are application processing outcomes, distinct from HTTP rejection. The [public create response contract](https://docs.gravitate.energy/docs/crossroads-api/order-create-ep-v-1-order-create-post/index.html) describes these statuses and makes the log nullable. A returned log or downstream order number is not required. Any supplied order number or log routing/metadata identity must not contradict the request. A bare HTTP 200, malformed response or unknown status is not this acknowledgment; existing HTTP and protocol failure classifications remain in effect.

This boundary assumes Crossroads retains acknowledged operations and its operators own downstream repair and replay. The module hands off subsequent events even if earlier processing needs a mapping or supply correction; it does not reproduce that recovery queue locally. The original response and downstream error remain in the receipt. `accepted` does not claim destination sync or completion. The legacy result boolean `synced` describes a locally finished request, including accepted/reconciled outcomes, not independently verified downstream state; use `status` and the stored response for that distinction.

Initialization applies the same acknowledgment check to existing rejected/pending receipts, including creates with no log, changing qualifying records to `sent/accepted` without a network request. Payloads, hashes, responses, and attempt history are preserved. The reconciliation is idempotent and releases local dependencies without replaying events already handed to Crossroads. Crossroads operators own downstream repair/retry; this module does not invoke the operator retry API. Newly changed payloads still send through the appropriate update/detail endpoint. Accepted receipts, including creation/existence proof, expire after two days under normal cleanup; receipts needed by pending dependents remain protected. This is not a permanent replay journal: replay suppression lasts only while the relevant receipt is retained.

URL, tenant pair, order, and logical request identify receipts. Hashes cover the base URL, tenant pair, path, and exact UTF-8 payload text, not the source update timestamp. Latest terminal receipts suppress replay; pending requests retry in sequence. A transient failure blocks later requests for that order only. Request files are replaced atomically, and receipts are saved before pending files are removed.

Request records carry `attempt_count`, `first_attempt_at`, `attempted_at` (latest tracked attempt), and `attempt_history_complete`. Counts are per retained payload hash, not lifetime order counts. Dispatch intent is saved immediately before the client call; interruption can leave an uncertain attempt even if the network never receives it. Status lookups, skipped dependencies and local `not_required` transitions do not increment it. New records start at zero with complete history; older records acquire tracking on their next dispatch with incomplete history. Missing tracking fields mean unknown history, not zero previous attempts. `first_attempt_at` is the first tracked attempt, not a reconstructed historical timestamp. A changed payload starts a new count; identical pending work preserves its count.

Creation lookups save a bounded `creation_check` on the pending request used for that order's check: check time, HTTP code, status, failed step, identity/route-match flags, destination-number presence, `exists` and `confirmed`. `confirmed` still means destination-sync proof; `exists` is the Crossroads prerequisite. This is the last readback, not another delivery attempt or a full event history. Raw lookup bodies and credentials are not copied into it. The record follows its request through normal supersession and receipt retention; it is not a permanent per-order journal.

Old object-format receipts and pending messages remain readable. Receipt lookup also recognizes compact JSON equivalents, so removing numeric padding does not resend successful requests. Only the latest receipt for each logical request is indexed. Old pending messages retain their queued representation until superseded or resolved. New messages are stored and sent unchanged through `CrossroadsClient -RawJson`. Terminal receipts age out under the existing retention rule, and pending messages remain until resolved.

CacheDir is optional on all delivery/cursor commands. Its default is the absolute `cache` path beneath the caller's current filesystem directory, evaluated on each call, never beneath the installed module. Set the working directory before running the integration. For an isolated test or another location, pass `-CacheDir $path` consistently to every delivery/cursor call. Existing positional arguments remain supported.

Public source commands require a nonblank BillTo. Receive, Add and Send require nonblank BaseUrl, Tenant and DestinationTenant values. Null, empty and whitespace-only values fail at parameter binding, before cache, SQL or HTTP work. Division remains optional on both TMW commands: omitted or empty selects all divisions for the billto. Callers requiring a particular division must configure it; there is no implicit division default.

Use a separate cache directory per feed/source/tenant pair. Delivery filters tenant pairs, but a cursor belongs to one source selection, not an arbitrary mix of customers. Keep staging, cursor advancement, sends, and persistence under one serialized job. Pending files do not expire; terminal receipts (including creation/existence proof) expire after two days except required dependency receipts and the latest rejected create while scoped dependent work lacks creation proof. Helpers retain the existing filename and hash formats.

When creation proof has expired or is missing, delivery first looks up the order on the configured route, including before a never-attempted create. Verified existence permits updates and retires a queued create as `sent/not_required` with `not_required_reason=order_exists`; this local transition preserves prior response/attempt evidence and makes no create request. It does not cover the current update or claim downstream recovery. Only a fresh exact scoped not-found result (the same check used for absent cancellations) permits creation. Failed, malformed, generic404, or otherwise unverifiable lookups leave work pending. A retained creation proof avoids that lookup until normal expiry; renewed lookup proof is also subject to normal expiry. Cleanup still uses the existing Clear-Files age calculation, not the source timestamp in receipt filenames.

### TMW Eligibility

The adapter excludes nonpositive freight and site/product totals that round to zero gallons. An excluded order still returns an empty snapshot with its source timestamp, so staging can retire obsolete pending requests and advance the cursor. Valid freight on the same order remains eligible.

Non-complete status requests include both `delivery_eta` and `eta` using the delivery estimate. `actual` remains the source event timestamp, or null when no event is recorded. Missing or invalid estimates omit the status without hiding eligible creates and updates. Completion requires its actual event time, not an estimate.

Delivery allocation slots map through `company_tankdetail.forecast_bucket` to `cmp_tank_id`; the slot number is not the tank ID. A unique, product-compatible tank assignment receives the freight's measured net quantity. Split allocations are sent only when every tank resolves and their quantities reconcile to the measured net total. A site's replace-mode drop is omitted if any positive freight line lacks usable allocation or timing data. No product-based fallback invents a delivered tank. Completion payloads are generated only when required BOL and drop data are eligible.

`Get-CrossroadsDeliveryCursor` reads the last staged source watermark. `Set-CrossroadsDeliveryCursor` advances it after all returned rows are staged. Receive coordinates these for the TMW adapter. Callers using the lower-level commands must preserve that ordering themselves. The caller owns logs, scheduling and publishing cache state.

## Runtime

PowerShell 7.5+, CrossroadsClient 1.0.3+, and Clear-Files. The SQL reader uses System.Data.SqlClient supplied with the PowerShell runtime. SQL Server integration has been exercised on Windows; offline package and delivery tests run on Windows and Linux. Driver replacement is not part of this module. Provide a connection string suitable for your server and platform; credentials are never bundled.

Import the manifest to check required modules and expose the nine public commands. The release workflow copies only its `FileList` into the package. Settings, credentials, cache, examples and tests stay outside it.

### Cache summary

```powershell
Get-CrossroadsDeliverySummary | Format-List
```

Call after Receive/Send, even when no results were returned. This read-only inventory uses one directory listing, not payload contents, and does not create a missing cache directory. Use `-CacheDir` for an explicit location; otherwise it uses `./cache` beneath the caller's current directory.

Pending, Rejected, Reconciled and Sent count request files, not orders. Rejected includes local holds; unchanged rejected requests are not retried automatically. Reconciled means already applied. Sent includes accepted handoffs and requests marked not required, not just downstream-synced responses. Zero pending does not mean every request was delivered or every destination order succeeded. TotalFiles and SizeMB include all top-level files, including cursor and unrecognized files; subdirectories are excluded. SizeMB uses 1,048,576 bytes per MB.

OldestPendingSourceUpdate and Cursor come from filename timestamps, not filesystem times changed by checkout. They remain in the adapter's source time convention (database-local for TMW); oldest pending source update is not first failure time. A quiet source can leave the cursor unchanged normally. Compare successive summaries to spot growing pending work or cache size; this is an inventory, not an automatic health verdict. Terminal receipts follow normal cleanup; pending requests do not expire.

Commands emit pipeline objects, not a guaranteed array object. Wrap calls in `@()` when a caller needs an empty array and a stable Count. The SQL reader joins every FOR JSON chunk before parsing, preserves UTC strings with `-DateKind String`, and rejects null chunks, malformed output, and extra result sets.

SQL builds the request fields and nesting. The TMW adapter compacts numeric serialization; its resulting `payload_json` stays opaque through hashing, persistence and HTTP. No request fields are added or reformatted by delivery.

## Operating Contract

The sender uses `/auth/token` with the password grant and the supplied client ID/secret. Obtain those credentials and the base URL from your Crossroads administrator. Requests use the supplied tenant headers. Never log tokens or secrets.

Run one writer per cache directory. Use persistent storage, not a disposable runner workspace without a persistence step. The caller stages a complete snapshot before advancing the cursor and makes both durable together. A crash after receiver acceptance but before receipt persistence can cause a repeat; this is at-least-once retry behavior, not exactly-once delivery. Explicit receiver rejections are retained as X40, not reported as successful delivery. Source changes not captured by your query cannot be recovered by the delivery queue.

The sender classifies Crossroads responses and preserves their error details. It recognizes specific duplicate-create and already-applied responses; it does not treat every HTTP 200 or 422 as successful. Processing is serial per order. No background service is installed.

Malformed successful responses reported by the client stay pending as `invalid_response`, retaining the actual HTTP code and raw response body. A protocol parsing error is not proof of delivery. Non-2xx responses retain their HTTP retry/rejection policy.
