. "$PSScriptRoot\helpers.ps1"
# Single schema now (see task-7-report.md): the codex-facing generation schema and the local
# structural-validation schema used to be two files differing only in a top-level if/then --
# the real API rejects our output schema with `invalid_json_schema: In context=(), 'if' is not
# permitted` (HTTP 400, BEFORE inference). Probing established 'if'/'then' is the ONLY offending
# keyword (minLength/maxLength/maxItems are all accepted). One file now serves BOTH
# --output-schema and local structural validation.
$schemaPath = "$PSScriptRoot\..\codex-review\schemas\verdict.schema.json"
$schema = Get-Content -Raw $schemaPath

# Regression guard: the schema must never regain a top-level if/then. That keyword is exactly
# what the real API rejected -- its return would silently reintroduce the HTTP 400 this schema
# collapse fixed, with no local test failure to catch it otherwise (Test-Json has no opinion on
# WHY a schema is shaped the way it is).
$schemaObj = $schema | ConvertFrom-Json
Assert-True ($schemaObj.PSObject.Properties.Name -notcontains 'if') "schema carries no top-level 'if' (the real API rejects it: invalid_json_schema)"
Assert-True ($schemaObj.PSObject.Properties.Name -notcontains 'then') "schema carries no top-level 'then'"

$rc = '{"verdict":"request_changes","summary":"Needs work.","recommendations":[{"severity":"blocking","location":"s2","issue":"X","suggestion":"Y"}]}'
Assert-True (Test-Json -Json $rc -Schema $schema) "schema: request_changes accepted"

$apNit = '{"verdict":"approve","summary":"Fine.","recommendations":[{"severity":"nit","location":"l3","issue":"typo","suggestion":"fix"}]}'
Assert-True (Test-Json -Json $apNit -Schema $schema) "schema: approve+nit accepted"

# Without if/then the schema no longer encodes the severity invariant (approve implies nit-only
# recommendations) -- it CANNOT: the real API rejects if/then outright. approve+important is
# therefore STRUCTURALLY VALID; Test-Verdict's normalization (see test-composer.ps1) is now the
# SOLE enforcement, downgrading it to request_changes before anything canonical is written or
# published. This replaces the old "codex schema REJECTS approve+important" assertion, which can
# no longer be true of any schema the real API will accept.
$apImportant = '{"verdict":"approve","summary":"x","recommendations":[{"severity":"important","location":"l","issue":"i","suggestion":"s"}]}'
Assert-True (Test-Json -Json $apImportant -Schema $schema) "schema: approve+important ACCEPTED structurally (normalization, not the schema, downgrades it)"

foreach ($case in @(
    @{j='{"verdict":"maybe","summary":"x","recommendations":[]}'; n='unknown verdict'},
    @{j='{"verdict":"approve","recommendations":[]}'; n='missing summary'},
    @{j='{"verdict":"approve","summary":"x","recommendations":[],"extra":1}'; n='additionalProperties'}
)) {
    Assert-True (-not (Test-Json -Json $case.j -Schema $schema -ErrorAction SilentlyContinue)) "schema rejects $($case.n)"
}
$tooMany = @{verdict='request_changes';summary='x';recommendations=@(1..21 | ForEach-Object { @{severity='nit';location='l';issue='i';suggestion='s'} })} | ConvertTo-Json -Depth 5
Assert-True (-not (Test-Json -Json $tooMany -Schema $schema -ErrorAction SilentlyContinue)) "schema rejects 21 items (maxItems 20)"
Write-TestResult
