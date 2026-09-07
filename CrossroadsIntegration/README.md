# CrossroadsIntegration

Unofficial PowerShell integration module for the [Gravitate Crossroads Integration API](https://docs.gravitate.energy/docs/crossroads-api/index.html). CrossroadsClient owns HTTP. This module owns source adapters, sequencing, pending requests, and receipts. It is not affiliated with Gravitate or the TMW vendor.

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

The included adapter reads a [Trimble TMW.Suite](https://transportation.trimble.com/en/solutions/transportation-management/tmw-suite-tms) fuel-hauling database directly through SQL; it does not call a Trimble API. It assumes Eastern database event times and converts outbound times to UTC in SQL. Source `updated_date` and cursor remain database-local for filtering. It reads orderheader, stops, freightdetail, company, commodity and referencenumber. It uses LLD/LUL stops, freight-linked BOLs and commodity classes 100/200 for net-volume selection. Verify these assumptions against your installation before enabling writes. Supply a reviewed `-SqlFile` override for another timezone, schema or business convention; the transport does not require this adapter.

Create volumes retain half-even integer rounding. BOL and drop quantities allow fractions per the API schema. SQL uses decimals to preserve source precision during JSON transport; the TMW adapter then uses the standard JSON serializer once to remove padding (`7900.0`, `100.1`). It does not round quantities to a fixed number of places. Numeric fixtures compare actual outgoing text with the previous converter.

## Delivery

Each complete envelope contains `order_number`, `updated_date`, `progress`, `hold`, and a `requests` array of `kind`, `path`, `message_key`, and `payload_json`. The payload is finished JSON text, not an object to rebuild. Include every current request for an order: staging supersedes obsolete pending messages. Do not feed partial status-only envelopes into delivery.

Supply one latest snapshot per order in each batch. Add rejects repeated order numbers before staging changes. A fresh successful create currently covers the accompanying update; the adapter must put all of that update's relevant fields in its create. Duplicate-create reconciliation does not skip the update.

URL, tenant pair, order, and logical request identify receipts. Hashes cover the base URL, tenant pair, path, and exact UTF-8 payload text, not the source update timestamp. Latest terminal receipts suppress replay; pending requests retry in sequence. A transient failure blocks later requests for that order only. Request files are replaced atomically, and receipts are saved before pending files are removed.

Old object-format receipts and pending messages remain readable. Receipt lookup also recognizes compact JSON equivalents, so removing numeric padding does not resend successful requests. Only the latest receipt for each logical request is indexed. Old pending messages retain their queued representation until superseded or resolved. New messages are stored and sent unchanged through `CrossroadsClient -RawJson`. Terminal receipts age out under the existing retention rule, and pending messages remain until resolved.

CacheDir is optional on all delivery/cursor commands. Its default is the absolute `cache` path beneath the caller's current filesystem directory, evaluated on each call, never beneath the installed module. Set the working directory before running the integration. For an isolated test or another location, pass `-CacheDir $path` consistently to every delivery/cursor call. Existing positional arguments remain supported.

Add-CrossroadsDelivery and Send-CrossroadsDelivery require a nonblank BaseUrl. Invalid values fail at parameter binding, before reading or writing delivery state or requesting a token.

Use a separate cache directory per feed/source/tenant pair. Delivery filters tenant pairs, but a cursor belongs to one source selection, not an arbitrary mix of customers. Keep staging, cursor advancement, sends, and persistence under one serialized job. Pending files do not expire; terminal receipts expire after one day. Helpers retain the existing filename and hash formats.

`Get-CrossroadsDeliveryCursor` reads the last staged source watermark. `Set-CrossroadsDeliveryCursor` advances it after all returned rows are staged. Receive coordinates these for the TMW adapter. Callers using the lower-level commands must preserve that ordering themselves. The caller owns logs, scheduling and publishing cache state.

## Runtime

PowerShell 7.5+, CrossroadsClient 1.0.3+, and Clear-Files. The SQL reader uses System.Data.SqlClient supplied with the PowerShell runtime. SQL Server integration has been exercised on Windows; offline package and delivery tests run on Windows and Linux. Driver replacement is not part of this module. Provide a connection string suitable for your server and platform; credentials are never bundled.

Import the manifest to check required modules and expose the nine public commands. The release workflow copies only its `FileList` into the package. Settings, credentials, cache, examples and tests stay outside it.

### Cache summary

```powershell
Get-CrossroadsDeliverySummary | Format-List
```

Call after Receive/Send, even when no results were returned. This read-only inventory uses one directory listing, not payload contents, and does not create a missing cache directory. Use `-CacheDir` for an explicit location; otherwise it uses `./cache` beneath the caller's current directory.

Pending, Rejected, Reconciled and Sent count request files, not orders. Rejected includes local holds; unchanged rejected requests are not retried automatically. Reconciled means already applied. Sent also includes requests marked not required. Zero pending does not mean every request was delivered. TotalFiles and SizeMB include all top-level files, including cursor and unrecognized files; subdirectories are excluded. SizeMB uses 1,048,576 bytes per MB.

OldestPendingSourceUpdate and Cursor come from filename timestamps, not filesystem times changed by checkout. They remain in the adapter's source time convention (database-local for TMW); oldest pending source update is not first failure time. A quiet source can leave the cursor unchanged normally. Compare successive summaries to spot growing pending work or cache size; this is an inventory, not an automatic health verdict. Terminal receipts follow normal cleanup; pending requests do not expire.

Commands emit pipeline objects, not a guaranteed array object. Wrap calls in `@()` when a caller needs an empty array and a stable Count. The SQL reader joins every FOR JSON chunk before parsing, preserves UTC strings with `-DateKind String`, and rejects null chunks, malformed output, and extra result sets.

SQL builds the request fields and nesting. The TMW adapter compacts numeric serialization; its resulting `payload_json` stays opaque through hashing, persistence and HTTP. No request fields are added or reformatted by delivery.

## Operating Contract

The sender uses `/auth/token` with the password grant and the supplied client ID/secret. Obtain those credentials and the base URL from your Crossroads administrator. Requests use the supplied tenant headers. Never log tokens or secrets.

Run one writer per cache directory. Use persistent storage, not a disposable runner workspace without a persistence step. The caller stages a complete snapshot before advancing the cursor and makes both durable together. A crash after receiver acceptance but before receipt persistence can cause a repeat; this is at-least-once retry behavior, not exactly-once delivery. Explicit receiver rejections are retained as X40, not reported as successful delivery. Source changes not captured by your query cannot be recovered by the delivery queue.

The sender classifies Crossroads responses and preserves their error details. It recognizes specific duplicate-create and already-applied responses; it does not treat every HTTP 200 or 422 as successful. Processing is serial per order. No background service is installed.

Malformed successful responses reported by the client stay pending as `invalid_response`, retaining the actual HTTP code and raw response body. A protocol parsing error is not proof of delivery. Non-2xx responses retain their HTTP retry/rejection policy.
