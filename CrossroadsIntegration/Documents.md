# BOL document delivery

This path is separate from order lifecycle delivery. EBE lives alongside the TMW
adapter; `CrossroadsClient` owns the multipart HTTP operation. Queries, scope,
credentials, scheduling and remote state persistence remain caller configuration.

## Source

`Get-CrossroadsEBEData -SqlFile <files> -ConnectionString <value> -Parameters <map>`
delegates to `Get-CrossroadsSqlData`. Supply a read-only query returning one JSON
column (`for json path`) with `document_id`, `order_number`, `bol_number`, and
`indexed_at`. The adapter returns string IDs and `file_name = EBE-<id>.pdf`.
Customer filtering, joins, time window and deterministic ordering belong to that
query. Return one extra row beyond the 2,000-item limit to detect truncation;
do not silently truncate the source to fit the budget.

`New-CrossroadsEBESession` takes the configured SHIPS base URL, username and password.
`Read-CrossroadsEBEDocument` takes that session and a document ID, returning PDF bytes
in memory only. Neither reads destination images or saves PDFs to disk.

Other sources can supply the same metadata shape, including a safe PDF filename,
and their own `ReadDocument` scriptblock. No EBE authentication occurs until the
scriptblock is invoked for an applied, ready item. For example:

```powershell
$source = @{ session = $null }
$readPdf = {
  param($document)
  if (-not $source.session) {
    $source.session = New-CrossroadsEBESession -BaseUrl $imagingUrl `
      -Username $readerName -Password $readerPassword
  }
  Read-CrossroadsEBEDocument -Session $source.session -DocumentId $document.document_id
}.GetNewClosure()

$results = Send-CrossroadsDocuments -Documents $documents -BaseUrl $apiUrl -Token $token `
  -Tenant $sourceTenant -DestinationTenant $destinationTenant -DestinationInstance $instance `
  -StateDirectory $stateDirectory -ReadDocument $readPdf -KeepDays 14
# Add -Apply for uploads and state writes. The default is metadata-only.
```

## Policy and state

State files live under `StateDirectory/cache` and `StateDirectory/claims`, not in
the installed module. The new key includes API URL, tenant pair, destination
instance, order number and BOL number. PDF content is not hashed. Rescans under
the same order/BOL are suppressed; this is not an image-update mechanism.

A valid receipt skips source and destination reads for that item. Otherwise the
order must match origin identity, tenant pair and instance. A destination order
number and matching destination BOL are required before upload. Any existing photo
metadata for that BOL suppresses a new upload. Only a metadata match for the attempted
filename resolves a new upload claim. Metadata is a confirmation signal, not a
downloaded-byte comparison or proof of all downstream processing.

The claim is persisted before the single POST. A receipt is persisted before claim
deletion. Unknown outcomes retain the claim, never automatically retry, and an
unresolved new attempt stops that run. Prior claims are checked even when their
source document has left the window. Failures propagate at their original site;
there is no catch-and-rethrow-generic wrapper. Callers can collect emitted result
rows and use `finally` to save an audit without replacing the error.

`KeepDays` defaults to 14 for ordinary document receipts; applied cleanup removes
at most 20 expired receipts per call. Unresolved claims never expire automatically.
Expiry alone does not authorize a resend: remote photo metadata and outstanding
claims still suppress it. This leaves existing order receipts and protected order
creation evidence unchanged. Source-window coverage remains the caller's concern.

`MaxUploads = 0` means no count cap. `BudgetSeconds = 480` and `MaxDocuments = 2000`
bound each call; the clock is checked between operations, not by interrupting a
POST. Individual SQL/HTTP requests have their own timeouts. Group output contains
results only for inspected items; uninspected items are not failed uploads.

## Ephemeral runners

By default state is persisted on the local filesystem. An ephemeral runner must
provide BOTH callbacks, backed by durable storage:

- `WriteState(path, json, createOnly)` returns exactly one boolean. For a claim,
  use an atomic create-if-absent. Return true only after durable confirmation;
  false means an existing competing claim or unconfirmed write, and never permits
  a POST. Receipt writes must be conditional when replacing an existing version.
- `RemoveState(path, existingJson)` conditionally deletes that exact stored version.
  Throw on failure or conflict. Return no output. The module then updates its local
  mirror. Do not delete uncertain claims manually based on one empty readback.

Paths are module-generated relative `cache/...` or `claims/...` paths. The callbacks
are the storage adapter, not a second owner of dedup policy. They must not log secrets.

## Existing state

`ReadLegacyState` is an explicit assertion that the supplied directory's unscoped
legacy files belong to this exact API/tenant/instance configuration. Legacy JSON
receipts still validate their stored tenant pair and instance; empty timestamped
markers have no embedded route and require this caller assertion. Supported old
claim keys are validated before readback. Never enable this for a mixed-route
directory. New records always use scoped keys; legacy receipts expire normally.

`PriorAttempts` accepts caller-scoped immutable historical attempts in the same
document shape. It only suppresses sends; it is not a replay or claim-deletion API.
No automatic migration discards prior evidence, and the module does not publish,
load, or copy any production state itself.
