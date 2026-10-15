# Manual fixtures only. Dot-sourcing performs no I/O, native initialization or dispatch.
function New-SourceWordReaderVector {
    $first='assertEquals(assertEquals, assertEquals, assertEquals, assertEquals, assertEquals) @near'
    $second='differentFailure(differentFailure, differentFailure, differentFailure, differentFailure, differentFailure)'
    $literal='literal @0 shared core @near'
    $third='expectedValue(expectedValue, expectedValue, expectedValue, expectedValue, expectedValue)'
    $bodies=@(
        "    $first`n        $first`n",
        "    $first`n    $second`n",
        "    $literal`n        $literal`n",
        "    $literal`n    $third`n",
        "    $first`n"
    )
    $tables=@(@('assertEquals'),@('differentFailure'),@(),@('expectedValue'),@('assertEquals'))
    $rows=@(
        "^~0=@0(@0, @0, @0, @0, @0) @near`n+~0~`n",
        "^~0~`n^~1=@0(@0, @0, @0, @0, @0)`n",
        "^~2=$literal`n+~2~`n",
        "^~2~`n^~3=@0(@0, @0, @0, @0, @0)`n",
        "^@0(@0, @0, @0, @0, @0) @near`n"
    )
    $ranges=@(@(0,1),@(1,2),@(2,3),@(3,4))
    $headers=@(); $wire=''; $blobs=@(); $patches=@()
    for ($i=0;$i -lt $bodies.Count;$i++) {
        $bytes=[Text.Encoding]::UTF8.GetBytes($bodies[$i])
        $prefix=[Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
        $blob=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([byte[]]($prefix+$bytes))).ToLowerInvariant()
        $blobs+=,$blob
        $path="src/manual-word-$i.kt"; $count=$bodies[$i].Split("`n").Length-1
        $h=if ($i -lt 4) { @('FL',$path,$blob.Substring(0,7),$count,$ranges[$i][0],$ranges[$i][1]) }
            else { @('F',$path,$blob.Substring(0,7),$count) }
        $legacy=ConvertTo-Json -InputObject $h -Compress
        $headers+=,$legacy
        $header=if ($i -eq 2) { $legacy } else { ConvertTo-Json -InputObject @('WORDS',$tables[$i],$legacy) -Depth 8 -Compress }
        $wire+=$header+"`n"+$rows[$i]
        $original="diff --git a/$path b/$path`nnew file mode 100644`nindex 0000000..$($blob.Substring(0,7))`n--- /dev/null`n+++ b/$path`n@@ -0,0 +1,$count @@`n"
        $patches+=,($original+'+'+$bodies[$i].Substring(0,$bodies[$i].Length-1).Replace("`n","`n+")+"`n")
    }
    $indexLines='index 0000000..'+$blobs[0].Substring(0,7)+"`n"+'index 0000000..'+$blobs[4].Substring(0,7)+"`n"
    $expected=($bodies -join "---NEXT---`n")+"---INDEXES---`n"+$indexLines
    [pscustomobject]@{Expected=$expected;IndexLines=$indexLines;LineCount=9;Positive=$wire;Bodies=$bodies;Blobs=$blobs;LegacyHeaders=$headers;Rows=$rows
        Patches=$patches;Tables=$tables;OriginalDiff=($patches -join '');LineDictionary=@($first,$second,$literal,$third)
        NegativeUnknown=$wire.Replace('^~1=@0(','^~1=@1(')
        NegativeAlias=$wire.Replace('^~1=@0(','^~1=@00(')
        NegativeBoundary=$wire.Replace('^~1=@0(','^~1=x@0(')
        NegativeForward=$wire.Replace('^~0~','^~9~')}
}
