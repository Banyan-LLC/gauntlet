# Offline synthetic evidence only. No live CLI, real auth or cleanup.
[CmdletBinding()]
param([string]$ArtifactRoot=[IO.Path]::GetTempPath(), [string]$GatePath=(Join-Path $PSScriptRoot 'live/live-security.ps1'))
. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference='Stop'
$fixtureRoot=Join-Path $ArtifactRoot ('encoded-diagnostics-test-'+[guid]::NewGuid().ToString('n'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($GatePath,[ref]$tokens,[ref]$errors)
foreach ($name in @('New-ControlDiagnosticStore','Add-ControlDiagnosticCredentials','Protect-ControlDiagnosticText','Get-ControlDiagnosticExcerpt','Write-FailedControlDiagnostic','Test-ControlDiagnosticDecodedSecret')) {
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if ($definition) { . ([scriptblock]::Create($definition.Extent.Text)) }
}
$store=New-ControlDiagnosticStore -Root $fixtureRoot -CredentialRoot (Join-Path $fixtureRoot 'credentials')
$edgeStore=New-ControlDiagnosticStore -Root $fixtureRoot -CredentialRoot (Join-Path $fixtureRoot 'credentials')
$invocationStore=New-ControlDiagnosticStore -Root $fixtureRoot -CredentialRoot (Join-Path $fixtureRoot 'credentials')
$rawStore=New-ControlDiagnosticStore -Root $fixtureRoot -CredentialRoot (Join-Path $fixtureRoot 'credentials')
$emojiStore=New-ControlDiagnosticStore -Root $fixtureRoot -CredentialRoot (Join-Path $fixtureRoot 'credentials')
$percentStores=[Collections.Generic.List[object]]::new()
$producer=@'
{
  "tokens": { "access_token": "synthetic-secret/for-encoding=42" },
  "marker": "???~~~"
}
'@
$bytes=[Text.Encoding]::UTF8.GetBytes($producer)
Add-ControlDiagnosticCredentials -Store $store -Bytes $bytes
Add-ControlDiagnosticCredentials -Store $edgeStore -Bytes $bytes
Add-ControlDiagnosticCredentials -Store $invocationStore -Bytes $bytes
Add-ControlDiagnosticCredentials -Store $rawStore -Bytes $bytes
$emojiSecret='secondary-sensitive-'+[char]::ConvertFromUtf32(0x1f600)
Add-ControlDiagnosticCredentials -Store $emojiStore -Bytes ([Text.Encoding]::UTF8.GetBytes((@{tokens=@{access_token=$emojiSecret}} | ConvertTo-Json -Compress)))
$original=[Convert]::ToBase64String($bytes)
$compact=$producer | ConvertFrom-Json -AsHashtable | ConvertTo-Json -Compress -Depth 8
$compactBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($compact))
$reordered='{"marker":"???~~~","tokens":{"access_token":"synthetic-secret/for-encoding=42"}}'
$escapedSecret=(-join ('synthetic-secret/for-encoding=42'.ToCharArray() | ForEach-Object { '\u'+([int]$_).ToString('x4') }))
$escapedDocument='{"tokens":{"access_token":"'+$escapedSecret+'"}}'
$utf16Document=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($compact))
$cases=@(
    @{Name='unpadded'; Value=$original.TrimEnd('=')},
    @{Name='base64url'; Value=$original.Replace('+','-').Replace('/','_').TrimEnd('=')},
    @{Name='reserialized'; Value=$compactBase64},
    @{Name='reordered'; Value=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($reordered))},
    @{Name='unicode'; Value=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($escapedDocument))},
    @{Name='utf16'; Value=$utf16Document},
    @{Name='utf16be'; Value=[Convert]::ToBase64String([Text.Encoding]::BigEndianUnicode.GetBytes($compact))},
    @{Name='nested'; Value=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($escapedDocument))))}
)
$wrappedDocument='{"message":"before '+$escapedSecret+' after"}'
$escapedEncoding=(-join ($utf16Document.ToCharArray() | ForEach-Object { '\u'+([int]$_).ToString('x4') }))
$edgeCases=@(
    @{Name='key-value'; Value='auth='+$original.TrimEnd('='); Expected='auth=[redacted]'},
    @{Name='wrapped-unicode'; Value=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($wrappedDocument)); Expected='[redacted]'},
    @{Name='utf16-prefix'; Value=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(([string][char]0x4f60+' '+ 'synthetic-secret/for-encoding=42'))); Expected='[redacted]'},
    @{Name='utf16be-prefix'; Value=[Convert]::ToBase64String([Text.Encoding]::BigEndianUnicode.GetBytes(([string][char]0x4f60+' '+ 'synthetic-secret/for-encoding=42'))); Expected='[redacted]'},
    @{Name='escaped-nested'; Value=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(('{"message":"'+$escapedEncoding+'"}'))); Expected='[redacted]'},
    @{Name='escaped-key'; Value=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(('{"'+$escapedSecret+'":"ordinary diagnostic"}'))); Expected='[redacted]'},
    @{Name='serialized-json'; Value=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{message=$escapedDocument} | ConvertTo-Json -Compress))); Expected='[redacted]'}
)
function Read-EncodedFixture {
    param($Path)
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $reader=[IO.StreamReader]::new($stream); return $reader.ReadToEnd() }
    finally { $stream.Dispose() }
}
try {
    Assert-True ($original.Contains('/') -and $original.Contains('+')) 'fixture exercises both Base64URL alphabet replacements'
    foreach ($case in $cases) {
        $result=[pscustomobject]@{Usable=$false;Reason='synthetic missing signal';InputTokens=12;Stdout=('{"type":"item.completed","item":{"type":"agent_message","text":"'+$case.Value+'"}}');Stderr=$case.Value;ExitCode=0;TimedOut=$false;StartFailed=$false}
        Write-FailedControlDiagnostic -Store $store -Name $case.Name -Executable 'C:\synthetic CLI\codex.exe' -Argv @('exec','--disable','shell_tool','-c','web_search="disabled"','') -Result $result | Out-Null
        $record=Read-EncodedFixture (Join-Path $store.Path ($case.Name+'.json')) | ConvertFrom-Json
        $event=$record.Stdout | ConvertFrom-Json
        Assert-Eq $event.item.text '[redacted]' "$($case.Name): the complete recoverable encoded blob is removed from retained model outcome"
        Assert-Eq $record.Stderr '[redacted]' "$($case.Name): the complete recoverable encoded blob is removed from retained stderr"
        Assert-True $record.Redacted "$($case.Name): metadata records encoded redaction"
        Assert-Eq ($record.Argv -join '|') 'exec|--disable|shell_tool|-c|web_search="disabled"|' "$($case.Name): trusted invocation boundaries remain exact"
        Assert-True (-not $record.Usable -and $record.ExitCode -eq 0 -and $record.InputTokens -eq 12) "$($case.Name): redaction does not alter process outcome metadata"
    }
    foreach ($case in $edgeCases) {
        $result=[pscustomobject]@{Usable=$false;Reason='synthetic missing signal';InputTokens=12;Stdout=('{"type":"item.completed","item":{"type":"agent_message","text":"'+$case.Value+'"}}');Stderr=$case.Value;ExitCode=0;TimedOut=$false;StartFailed=$false}
        $benignPath='C:\eyJ4eCI6\codex.exe'
        Write-FailedControlDiagnostic -Store $edgeStore -Name $case.Name -Executable $benignPath -Argv @('exec','eyJ4eCI6','') -Result $result | Out-Null
        $record=Read-EncodedFixture (Join-Path $edgeStore.Path ($case.Name+'.json')) | ConvertFrom-Json
        $event=$record.Stdout | ConvertFrom-Json
        Assert-Eq $event.item.text $case.Expected "$($case.Name): retained model output removes the whole encoded credential"
        Assert-Eq $record.Stderr $case.Expected "$($case.Name): retained stderr removes the whole encoded credential"
        Assert-True $record.Redacted "$($case.Name): metadata records encoded redaction"
        Assert-Eq $record.Executable $benignPath "$($case.Name): a credential-free executable containing malformed encoded JSON remains exact"
        Assert-Eq ($record.Argv -join '|') 'exec|eyJ4eCI6|' "$($case.Name): credential-free arguments and an empty boundary remain exact"
        Assert-True (-not $record.Usable -and $record.ExitCode -eq 0 -and $record.InputTokens -eq 12) "$($case.Name): process outcome metadata remains exact"
    }
    $spanTail=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($escapedDocument))))
    $manySpans=(('synthetic-secret/for-encoding=42 ')*4095)+$spanTail
    Assert-True ((Protect-ControlDiagnosticText -Store $store -Text $manySpans) -ceq '[redacted: diagnostic scan budget]') 'direct, nested and outer redaction spans share the same per-field cap'
    $rawValue='{"summary":"before '+$escapedSecret+' after","exit":0}'
    $rawKey='{"'+$escapedSecret+'":"ordinary diagnostic"}'
    $rawNative='{"type":"thread.started","thread_id":"synthetic-thread"}'+"`n"+'{"type":"item.completed","item":{"type":"agent_message","text":"'+$escapedSecret+'"}}'+"`n"+'{"type":"turn.completed","usage":{"input_tokens":12}}'
    $rawError='{"error":"'+$escapedEncoding+'"}'
    $rawResult=[pscustomobject]@{Usable=$false;Reason=$rawValue;InputTokens=12;Stdout=$rawNative;Stderr=$rawKey;ExitCode=0;TimedOut=$false;StartFailed=$false}
    Write-FailedControlDiagnostic -Store $rawStore -Name 'raw-json-lines' -Executable 'C:\synthetic CLI\codex.exe' -Argv @('exec','-c','web_search="disabled"','') -Result $rawResult -Error $rawError | Out-Null
    $rawRecord=Read-EncodedFixture (Join-Path $rawStore.Path 'raw-json-lines.json') | ConvertFrom-Json
    $nativeEvents=@($rawRecord.Stdout -split "`n" | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-Eq $nativeEvents.Count 3 'native JSON-lines keep all event boundaries'
    Assert-Eq $nativeEvents[0].thread_id 'synthetic-thread' 'raw JSON inspection preserves thread metadata'
    Assert-Eq $nativeEvents[1].item.text '[redacted]' 'Unicode credentials are removed from native model JSON strings'
    Assert-Eq $nativeEvents[1].item.type 'agent_message' 'raw JSON inspection preserves the model event type'
    Assert-Eq $nativeEvents[2].usage.input_tokens 12 'raw JSON inspection preserves terminal usage'
    $stderrJson=$rawRecord.Stderr | ConvertFrom-Json -AsHashtable
    Assert-True (-not $stderrJson.Contains('synthetic-secret/for-encoding=42')) 'Unicode credentials in raw JSON property names cannot be recovered'
    Assert-Eq $stderrJson['[redacted]'] 'ordinary diagnostic' 'raw JSON key redaction preserves the associated diagnostic value'
    Assert-Eq (($rawRecord.Reason | ConvertFrom-Json).summary) '[redacted]' 'raw JSON reasons remove contained escaped credentials'
    Assert-Eq (($rawRecord.Reason | ConvertFrom-Json).exit) 0 'raw JSON reasons preserve unrelated outcome metadata'
    Assert-Eq (($rawRecord.Error | ConvertFrom-Json).error) '[redacted]' 'raw JSON errors inspect escaped nested encoding'
    Assert-True $rawRecord.Redacted 'raw JSON redaction is reported'
    Assert-Eq ($rawRecord.Argv -join '|') 'exec|-c|web_search="disabled"|' 'raw JSON redaction keeps exact invocation boundaries'
    Assert-True (-not $rawRecord.Usable -and $rawRecord.ExitCode -eq 0 -and $rawRecord.InputTokens -eq 12) 'raw JSON redaction preserves process outcome metadata'
    foreach ($invocationCase in @(@{Name='raw-value-argv';Text=$rawValue},@{Name='raw-key-argv';Text=$rawKey},@{Name='raw-lines-argv';Text=$rawNative})) {
        Assert-Throws { Write-FailedControlDiagnostic -Store $invocationStore -Name $invocationCase.Name -Executable 'codex.exe' -Argv @($invocationCase.Text) -Result $rawResult } "$($invocationCase.Name): recoverable raw JSON in invocation refuses exact retention"
        Assert-True (-not [IO.File]::Exists((Join-Path $invocationStore.Path ($invocationCase.Name+'.json')))) "$($invocationCase.Name): refusal creates no diagnostic record"
    }
    $benignNative='{"type":"item.completed","item":{"type":"agent_message","text":"NO_APPS_AVAILABLE"}}'+"`n"+'{"type":"turn.completed","usage":{"input_tokens":12}}'
    $benignResult=[pscustomobject]@{Usable=$false;Reason='missing signal';InputTokens=12;Stdout=$benignNative;Stderr='{"notice":"ordinary diagnostic"}';ExitCode=0;TimedOut=$false;StartFailed=$false}
    Write-FailedControlDiagnostic -Store $rawStore -Name 'benign-json-lines' -Executable 'C:\synthetic CLI\codex.exe' -Argv @('exec',$benignNative,'') -Result $benignResult | Out-Null
    $benignRecord=Read-EncodedFixture (Join-Path $rawStore.Path 'benign-json-lines.json') | ConvertFrom-Json
    Assert-Eq $benignRecord.Stdout $benignNative 'benign native JSON-lines remain byte-for-character exact'
    Assert-Eq $benignRecord.Stderr $benignResult.Stderr 'benign raw JSON stderr remains exact'
    Assert-Eq $benignRecord.Argv[1] $benignNative 'benign JSON-lines argument remains exact'
    Assert-Eq $benignRecord.Argv[2] '' 'raw JSON invocation keeps empty arguments'
    Assert-True (-not $benignRecord.Redacted -and -not $benignRecord.Truncated) 'benign metadata does not falsely report redaction or truncation'
    $bareNative=@{type='item.completed';item=@{type='agent_message';text=$escapedSecret}} | ConvertTo-Json -Compress -Depth 8
    $bareResult=[pscustomobject]@{Usable=$false;Reason='missing signal';InputTokens=12;Stdout=$bareNative;Stderr=$escapedSecret;ExitCode=0;TimedOut=$false;StartFailed=$false}
    Write-FailedControlDiagnostic -Store $rawStore -Name 'native-bare-escapes' -Executable 'codex.exe' -Argv @('exec','') -Result $bareResult | Out-Null
    $bareRecord=Read-EncodedFixture (Join-Path $rawStore.Path 'native-bare-escapes.json') | ConvertFrom-Json
    $bareEvent=$bareRecord.Stdout | ConvertFrom-Json
    Assert-Eq $bareEvent.item.text '[redacted]' 'real JSON serialization of bare Unicode escape text cannot retain a recoverable credential'
    Assert-Eq $bareEvent.type 'item.completed' 'bare escape redaction preserves native event metadata'
    Assert-Eq $bareRecord.Stderr '[redacted]' 'unquoted Unicode credential escapes are removed from stderr'
    Assert-True $bareRecord.Redacted 'bare escape redaction is reported'
    Assert-Throws { Write-FailedControlDiagnostic -Store $invocationStore -Name 'bare-argv' -Executable 'codex.exe' -Argv @($bareNative) -Result $bareResult } 'native serialized bare escape content refuses exact invocation retention'
    Assert-True (-not [IO.File]::Exists((Join-Path $invocationStore.Path 'bare-argv.json'))) 'bare escape invocation refusal creates no record'
    $benignEscapes=-join ('ordinary diagnostic'.ToCharArray() | ForEach-Object { '\u'+([int]$_).ToString('x4') })
    Assert-Eq (Protect-ControlDiagnosticText -Store $store -Text $benignEscapes) $benignEscapes 'benign bare escape text stays exact'
    $benignBareNative=@{type='item.completed';item=@{type='agent_message';text=$benignEscapes}} | ConvertTo-Json -Compress -Depth 8
    $benignBareResult=[pscustomobject]@{Usable=$false;Reason='missing signal';InputTokens=12;Stdout=$benignBareNative;Stderr=$benignEscapes;ExitCode=0;TimedOut=$false;StartFailed=$false}
    Write-FailedControlDiagnostic -Store $rawStore -Name 'benign-native-escapes' -Executable 'codex.exe' -Argv @('exec',$benignBareNative,'') -Result $benignBareResult | Out-Null
    $benignBareRecord=Read-EncodedFixture (Join-Path $rawStore.Path 'benign-native-escapes.json') | ConvertFrom-Json
    Assert-Eq $benignBareRecord.Stdout $benignBareNative 'real native serialization of benign bare escapes remains exact'
    Assert-Eq $benignBareRecord.Stderr $benignEscapes 'benign escaped stderr stays exact'
    Assert-Eq $benignBareRecord.Argv[1] $benignBareNative 'benign native escaped invocation remains exact'
    Assert-True (-not $benignBareRecord.Redacted -and -not $benignBareRecord.Truncated) 'benign native escape metadata stays unchanged'
    Assert-True (-not $benignBareRecord.Usable -and $benignBareRecord.ExitCode -eq 0 -and $benignBareRecord.InputTokens -eq 12) 'benign native escape inspection preserves process outcome'
    Assert-Eq (Protect-ControlDiagnosticText -Store $store -Text $escapedSecret.Replace('\','\\')) '[redacted]' 'multiple bare JSON escape layers use the same recursive credential checks'
    $deepBare=$escapedSecret
    for ($layer=0; $layer -lt 4; $layer++) { $deepBare=$deepBare.Replace('\','\\') }
    Assert-Eq (Protect-ControlDiagnosticText -Store $store -Text $deepBare) '[redacted: diagnostic scan budget]' 'bare escape recursion cannot exceed the shared encoding depth'
    $solidus='synthetic-secret\/for-encoding=42'
    $solidusNative=@{type='item.completed';item=@{type='agent_message';text=$solidus}} | ConvertTo-Json -Compress -Depth 8
    $solidusResult=[pscustomobject]@{Usable=$false;Reason='missing signal';InputTokens=12;Stdout=$solidusNative;Stderr=$solidus;ExitCode=0;TimedOut=$false;StartFailed=$false}
    Write-FailedControlDiagnostic -Store $rawStore -Name 'native-solidus-escapes' -Executable 'codex.exe' -Argv @('exec','') -Result $solidusResult | Out-Null
    $solidusRecord=Read-EncodedFixture (Join-Path $rawStore.Path 'native-solidus-escapes.json') | ConvertFrom-Json
    Assert-Eq (($solidusRecord.Stdout | ConvertFrom-Json).item.text) '[redacted]' 'native serialized non-Unicode JSON escapes cannot retain credentials'
    Assert-Eq $solidusRecord.Stderr '[redacted]' 'bare escaped solidus credentials are redacted'
    Assert-Eq (($solidusRecord.Stdout | ConvertFrom-Json).type) 'item.completed' 'non-Unicode escape redaction preserves event metadata'
    Assert-True $solidusRecord.Redacted 'non-Unicode escape redaction is reported'
    Assert-Throws { Write-FailedControlDiagnostic -Store $invocationStore -Name 'solidus-argv' -Executable 'codex.exe' -Argv @($solidusNative) -Result $solidusResult } 'non-Unicode escaped credentials refuse exact invocation retention'
    Assert-True (-not [IO.File]::Exists((Join-Path $invocationStore.Path 'solidus-argv.json'))) 'solidus invocation refusal creates no record'
    $windowsPath='C:\Users\synthetic\AppData\Local\OpenAI\Codex\bin\pinned\codex.exe'
    Write-FailedControlDiagnostic -Store $rawStore -Name 'benign-windows-path' -Executable $windowsPath -Argv @('exec',$windowsPath,'') -Result $benignResult | Out-Null
    $windowsRecord=Read-EncodedFixture (Join-Path $rawStore.Path 'benign-windows-path.json') | ConvertFrom-Json
    Assert-Eq $windowsRecord.Executable $windowsPath 'ordinary Windows path containing valid and invalid JSON escape prefixes remains exact'
    Assert-Eq $windowsRecord.Argv[1] $windowsPath 'Windows argument path remains exact'
    Assert-True (-not $windowsRecord.Redacted) 'ordinary Windows path is not falsely labeled as redacted'
    $emojiEscapes=-join ($emojiSecret.ToCharArray() | ForEach-Object { '\u'+([int]$_).ToString('x4') })
    $emojiNative=@{type='item.completed';item=@{type='agent_message';text=$emojiEscapes}} | ConvertTo-Json -Compress -Depth 8
    $emojiResult=[pscustomobject]@{Usable=$false;Reason='missing signal';InputTokens=12;Stdout=$emojiNative;Stderr=$emojiEscapes;ExitCode=0;TimedOut=$false;StartFailed=$false}
    Write-FailedControlDiagnostic -Store $emojiStore -Name 'surrogate-escapes' -Executable 'codex.exe' -Argv @('exec') -Result $emojiResult | Out-Null
    $emojiRecord=Read-EncodedFixture (Join-Path $emojiStore.Path 'surrogate-escapes.json') | ConvertFrom-Json
    Assert-Eq (($emojiRecord.Stdout | ConvertFrom-Json).item.text) '[redacted]' 'native escaped surrogate pairs cannot retain a recoverable known credential'
    Assert-True ($emojiRecord.Stderr -match '^\[redacted') 'bare Unicode surrogate pairs are inspected without leaking their spelling'
    Assert-Eq (($emojiRecord.Stdout | ConvertFrom-Json).type) 'item.completed' 'surrogate inspection preserves event metadata'
    Assert-Throws { Write-FailedControlDiagnostic -Store $emojiStore -Name 'surrogate-argv' -Executable 'codex.exe' -Argv @($emojiNative) -Result $emojiResult } 'supplementary Unicode credentials refuse invocation retention'
    Assert-True (-not [IO.File]::Exists((Join-Path $emojiStore.Path 'surrogate-argv.json'))) 'surrogate invocation refusal creates no record'
    $mixedEscapes='synthetic-\u0073ecret/for-encoding=42'
    # Removing bounded percent decoding must expose recoverable credentials in actual records.
    $percentSecret='synthetic/secret+case=987'
    $percentProducer='{"tokens":{"access_token":"synthetic/secret+case=987"}}'
    $percentLower='synthetic%2fsecret%2bcase%3d987'
    $percentBase64='c3ludGhldGljJTJmc2VjcmV0JTJiY2FzZSUzZDk4Nw=='
    $percentJson='{"notice":"synthetic%2fsecret%2bcase%3d987"}'
    $percentKey='{"synthetic%2fsecret%2bcase%3d987":"ordinary diagnostic"}'
    $percentDocument=[regex]::Replace([Uri]::EscapeDataString($percentProducer),'%[0-9A-Fa-f]{2}',{param($match) $match.Value.ToLowerInvariant()})
    $percentEmoji='synthetic/secret+'+[char]::ConvertFromUtf32(0x1f600)+'=987'
    $overlapBlob=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('ordinary metadata prefix secondary-sensitive%2fsecret%3dXYZ'))
    $percentCases=@(
        @{Name='lower';Text=$percentLower;Expected='[redacted]';Native='[redacted]'},
        @{Name='mixed';Text='synthetic%2fsecret%2Bcase%3d987';Expected='[redacted]';Native='[redacted]'},
        @{Name='partial';Text='synthetic%2fsecret+case=987';Expected='[redacted]';Native='[redacted]'},
        @{Name='unreserved';Text='synthetic/%73ecret+case=987';Expected='[redacted]';Native='[redacted]'},
        @{Name='wrapped';Text='before synthetic%2fsecret%2bcase%3d987 after';Expected='before [redacted] after';Native='before [redacted] after'},
        @{Name='adjacent';Text='%70refixsynthetic%2fsecret%2bcase%3d987suffix';Expected='%70refix[redacted]suffix';Native='%70refix[redacted]suffix'},
        @{Name='twice';Text='synthetic%252fsecret%252bcase%253d987';Expected='[redacted]';Native='[redacted]'},
        @{Name='shared-token';Text='synthetic%2fsecret%2bcase%3d987,synthetic%252fsecret%252bcase%253d987';Expected='[redacted]';Native='[redacted]'},
        @{Name='base64';Text=$percentBase64;Expected='[redacted]';Native='[redacted]'},
        @{Name='nested-base64';Text=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($percentBase64));Expected='[redacted]';Native='[redacted]'},
        @{Name='json-value';Text=$percentJson;Expected='{"notice":"[redacted]"}';Native='[redacted]'},
        @{Name='json-key';Text=$percentKey;Expected='{"[redacted]":"ordinary diagnostic"}';Native='[redacted]'},
        @{Name='base64-json';Text=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($percentJson));Expected='[redacted]';Native='[redacted]'},
        @{Name='serialized-json';Text=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{message=$percentJson} | ConvertTo-Json -Compress)));Expected='[redacted]';Native='[redacted]'},
        @{Name='document';Text=$percentDocument;Expected='[redacted]';Native='[redacted]'},
        @{Name='utf8';Text='synthetic%2fsecret%2b%f0%9f%98%80%3d987';Expected='[redacted]';Native='[redacted]';Secret=$percentEmoji}
    )
    foreach ($overlapLength in @(5,6,7,9,10)) {
        $overlapProducer=@{tokens=@{first=$overlapBlob.Substring(0,$overlapLength);second='secondary-sensitive/secret=XYZ'}} | ConvertTo-Json -Compress
        $percentCases+=@{Name="overlap-$overlapLength";Text='%62'+$overlapBlob.Substring(1);Expected='[redacted]';Native='[redacted]';Producer=$overlapProducer}
    }
    foreach ($percentCase in $percentCases) {
        $percentStore=New-ControlDiagnosticStore -Root $fixtureRoot -CredentialRoot (Join-Path $fixtureRoot 'credentials')
        $percentStores.Add($percentStore)
        $percentProducerText=if ($percentCase.ContainsKey('Producer')) { $percentCase.Producer } elseif ($percentCase.ContainsKey('Secret')) { @{tokens=@{access_token=$percentCase.Secret}} | ConvertTo-Json -Compress } else { $percentProducer }
        Add-ControlDiagnosticCredentials -Store $percentStore -Bytes ([Text.Encoding]::UTF8.GetBytes($percentProducerText))
        $percentNative=@{type='item.completed';item=@{type='agent_message';text=$percentCase.Text}} | ConvertTo-Json -Compress -Depth 8
        $percentResult=[pscustomobject]@{Usable=$false;Reason=$percentCase.Text;InputTokens=12;Stdout=$percentNative;Stderr=$percentCase.Text;ExitCode=0;TimedOut=$false;StartFailed=$false}
        Write-FailedControlDiagnostic -Store $percentStore -Name 'percent-record' -Executable 'codex.exe' -Argv @('exec','') -Result $percentResult -Error $percentCase.Text | Out-Null
        $percentRecord=Read-EncodedFixture (Join-Path $percentStore.Path 'percent-record.json') | ConvertFrom-Json
        $percentEvent=$percentRecord.Stdout | ConvertFrom-Json
        Assert-Eq $percentEvent.item.text $percentCase.Native "$($percentCase.Name): native retained model output removes the recoverable percent credential"
        Assert-Eq $percentEvent.type 'item.completed' "$($percentCase.Name): native event metadata remains exact"
        foreach ($percentField in @('Stderr','Reason','Error')) {
            Assert-Eq $percentRecord.$percentField $percentCase.Expected "$($percentCase.Name): actual retained $percentField removes the recoverable percent credential"
        }
        Assert-True $percentRecord.Redacted "$($percentCase.Name): percent redaction is reported"
        Assert-True (-not $percentRecord.Usable -and $percentRecord.ExitCode -eq 0 -and $percentRecord.InputTokens -eq 12 -and -not $percentRecord.TimedOut -and -not $percentRecord.StartFailed) "$($percentCase.Name): process outcomes remain exact"
        Assert-Eq ($percentRecord.Argv -join '|') 'exec|' "$($percentCase.Name): empty argument boundaries remain exact"
        Assert-Throws { Write-FailedControlDiagnostic -Store $percentStore -Name 'percent-argv' -Executable 'codex.exe' -Argv @($percentCase.Text) -Result $percentResult } "$($percentCase.Name): known percent credentials refuse argv retention"
        Assert-True (-not [IO.File]::Exists((Join-Path $percentStore.Path 'percent-argv.json'))) "$($percentCase.Name): argv refusal creates no record"
        Assert-Throws { Write-FailedControlDiagnostic -Store $percentStore -Name 'percent-executable' -Executable $percentCase.Text -Argv @('exec') -Result $percentResult } "$($percentCase.Name): known percent credentials refuse executable retention"
        Assert-True (-not [IO.File]::Exists((Join-Path $percentStore.Path 'percent-executable.json'))) "$($percentCase.Name): executable refusal creates no record"
        Assert-Eq $percentStore.Count 1 "$($percentCase.Name): invocation refusal does not rely on the eight-record cap"
    }
    $benignPercent='ordinary%2fnotice%2bcase%3d987 %22quoted%22 %G1 100%done'
    $benignPercentNative=@{type='item.completed';item=@{type='agent_message';text=$benignPercent}} | ConvertTo-Json -Compress -Depth 8
    $benignPercentResult=[pscustomobject]@{Usable=$false;Reason=$benignPercent;InputTokens=12;Stdout=$benignPercentNative;Stderr=$benignPercent;ExitCode=0;TimedOut=$false;StartFailed=$false}
    $benignPercentStore=New-ControlDiagnosticStore -Root $fixtureRoot -CredentialRoot (Join-Path $fixtureRoot 'credentials')
    $percentStores.Add($benignPercentStore)
    Add-ControlDiagnosticCredentials -Store $benignPercentStore -Bytes ([Text.Encoding]::UTF8.GetBytes($percentProducer))
    $benignPercentExecutable='C:\percent%2fordinary\codex.exe'
    Write-FailedControlDiagnostic -Store $benignPercentStore -Name 'benign-percent' -Executable $benignPercentExecutable -Argv @($benignPercent,'') -Result $benignPercentResult -Error $benignPercent | Out-Null
    $benignPercentRecord=Read-EncodedFixture (Join-Path $benignPercentStore.Path 'benign-percent.json') | ConvertFrom-Json
    Assert-Eq $benignPercentRecord.Stdout $benignPercentNative 'benign percent native output remains exact'
    foreach ($percentField in @('Stderr','Reason','Error')) { Assert-Eq $benignPercentRecord.$percentField $benignPercent "benign percent $percentField remains exact" }
    Assert-Eq $benignPercentRecord.Executable $benignPercentExecutable 'benign percent executable remains exact'
    Assert-Eq $benignPercentRecord.Argv[0] $benignPercent 'benign percent argument remains exact'
    Assert-Eq $benignPercentRecord.Argv[1] '' 'benign percent invocation preserves empty arguments'
    Assert-True (-not $benignPercentRecord.Redacted -and -not $benignPercentRecord.Truncated) 'benign percent inspection does not report false redaction or truncation'
    $percentDepth=$percentLower
    for ($layer=0;$layer -lt 4;$layer++) { $percentDepth=$percentDepth.Replace('%','%25') }
    Assert-Eq (Protect-ControlDiagnosticText -Store $benignPercentStore -Text $percentDepth) '[redacted: diagnostic scan budget]' 'nested percent decoding cannot exceed the shared four-layer bound'
    Assert-Eq (Protect-ControlDiagnosticText -Store $store -Text $mixedEscapes) '[redacted]' 'Unicode inspection checks mixed literal and escaped credential content'
    Assert-Eq (Protect-ControlDiagnosticText -Store $store -Text ('synthetic-secret/for-encoding=42 '+$escapedSecret)) '[redacted]' 'a literal credential span cannot hide another escaped credential in the same field'
    $badCases=@(
        @{Name='partial-json-lines';Text='{"type":"item.completed","item":{"type":"agent_message","text":"'+$escapedSecret},
        @{Name='invalid-json-escape';Text='{"message":"'+$escapedSecret+'\q"}'}
    )
    foreach ($badCase in $badCases) {
        $badResult=[pscustomobject]@{Usable=$false;Reason='synthetic timeout';InputTokens=12;Stdout=('{"type":"thread.started"}'+"`n"+$badCase.Text);Stderr=$badCase.Text;ExitCode=1;TimedOut=$true;StartFailed=$false}
        Write-FailedControlDiagnostic -Store $rawStore -Name $badCase.Name -Executable 'codex.exe' -Argv @('exec','') -Result $badResult | Out-Null
        $badRecord=Read-EncodedFixture (Join-Path $rawStore.Path ($badCase.Name+'.json')) | ConvertFrom-Json
        Assert-Eq $badRecord.Stdout '[redacted: diagnostic scan incomplete]' "$($badCase.Name): incomplete native stream is refused as raw retained output"
        Assert-Eq $badRecord.Stderr '[redacted: diagnostic scan incomplete]' "$($badCase.Name): malformed quoted stderr cannot retain recoverable credential fragments"
        Assert-True $badRecord.Redacted "$($badCase.Name): incomplete inspection is labeled"
        Assert-True (-not $badRecord.Usable -and $badRecord.ExitCode -eq 1 -and $badRecord.TimedOut) "$($badCase.Name): incomplete inspection preserves process outcome metadata"
        Assert-Throws { Write-FailedControlDiagnostic -Store $invocationStore -Name ($badCase.Name+'-argv') -Executable 'codex.exe' -Argv @($badCase.Text) -Result $badResult } "$($badCase.Name): incomplete invocation inspection refuses creation"
        Assert-True (-not [IO.File]::Exists((Join-Path $invocationStore.Path ($badCase.Name+'-argv.json')))) "$($badCase.Name): invocation refusal creates no partial record"
    }
    $manyJsonTokens=('"a"'+"`n")*8193
    Assert-True ((Protect-ControlDiagnosticText -Store $store -Text $manyJsonTokens) -ceq '[redacted: diagnostic scan budget]') 'raw JSON string tokens consume the shared JSON inspection cap'
    Assert-Throws { Write-FailedControlDiagnostic -Store $invocationStore -Name 'secret-argv' -Executable 'codex.exe' -Argv @('synthetic-secret/for-encoding=42') -Result $result } 'credential-bearing invocation is refused rather than published with altered arguments'
    Assert-True (-not [IO.File]::Exists((Join-Path $invocationStore.Path 'secret-argv.json'))) 'refused invocation creates no partial diagnostic record'
    Assert-Throws { Write-FailedControlDiagnostic -Store $invocationStore -Name 'encoded-argv' -Executable 'codex.exe' -Argv @($compactBase64) -Result $result } 'an encoded credential in trusted arguments also refuses exact retention'
    Assert-True (-not [IO.File]::Exists((Join-Path $invocationStore.Path 'encoded-argv.json'))) 'encoded invocation refusal creates no diagnostic record'
    $benign=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"notice":"ordinary diagnostic","sequence":42}'))
    Assert-Eq (Protect-ControlDiagnosticText -Store $store -Text $benign) $benign 'unrelated encoded JSON remains available for diagnosis'
    $plain='NO_APPS_AVAILABLE: connector was unavailable. --ignore-user-config --disable shell_tool'
    Assert-Eq (Protect-ControlDiagnosticText -Store $store -Text $plain) $plain 'ordinary model outcome and capability names remain readable'
    $folded=($compactBase64.Substring(0,32)+"`r`n"+$compactBase64.Substring(32))
    Assert-Eq (Protect-ControlDiagnosticText -Store $store -Text $folded) '[redacted]' 'MIME line folding cannot bypass whole-document protection'
    $decodedBudget='{"tokens":{"access_token":"'+('x'*300000)+'"}}'
    $oversized=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($decodedBudget))
    Assert-True ((Protect-ControlDiagnosticText -Store $store -Text $oversized) -ceq '[redacted]') 'oversized encoded blobs are conservatively redacted instead of exceeding the decoding budget'
    $manyCandidates=(($benign+' ')*300)
    Assert-True ((Protect-ControlDiagnosticText -Store $store -Text $manyCandidates).Contains('[redacted: diagnostic scan budget]')) 'candidate work exhaustion redacts the field rather than leaving an unchecked tail'
    Assert-Throws { Write-FailedControlDiagnostic -Store $invocationStore -Name 'budget-argv' -Executable 'codex.exe' -Argv @($manyCandidates) -Result $result } 'unverifiable invocation work is refused rather than replaced with an approximate argv'
    Assert-True (-not [IO.File]::Exists((Join-Path $invocationStore.Path 'budget-argv.json'))) 'invocation budget refusal creates no diagnostic record'
    Assert-Eq $invocationStore.Count 0 'all invocation refusals preserve the successful-record count without relying on the file cap'
    $serializedDepth=$escapedDocument
    for ($layer=0; $layer -lt 5; $layer++) { $serializedDepth=@{message=$serializedDepth} | ConvertTo-Json -Compress }
    $deepJson=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($serializedDepth))
    Assert-True ((Protect-ControlDiagnosticText -Store $store -Text $deepJson) -ceq '[redacted: diagnostic scan budget]') 'serialized JSON inspection consumes the shared encoding depth instead of opening unbounded recursion'
    $jwtPayload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"subject":"synthetic-secret/for-encoding=42"}')).Replace('+','-').Replace('/','_').TrimEnd('=')
    $syntheticJwt='synthetic-header.'+$jwtPayload+'.synthetic-signature'
    Add-ControlDiagnosticCredentials -Store $store -Bytes ([Text.Encoding]::UTF8.GetBytes(('{"tokens":{"id_token":"'+$syntheticJwt+'"}}')))
    Assert-Eq (Protect-ControlDiagnosticText -Store $store -Text $syntheticJwt) '[redacted]' 'encoded payload redaction cannot break detection of a known full credential spanning token boundaries'
} finally { $store.Custody.Dispose(); $edgeStore.Custody.Dispose(); $invocationStore.Custody.Dispose(); $rawStore.Custody.Dispose(); $emojiStore.Custody.Dispose(); foreach ($percentStore in $percentStores) { $percentStore.Custody.Dispose() } }
Write-Host "Synthetic evidence: $fixtureRoot"
Write-TestResult
