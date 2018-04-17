Param(
    [Parameter(Mandatory = $true)] [pscredential]$Credential,
    [Parameter(Mandatory = $true)] [string]$Method,
    [Parameter(Mandatory = $true)] [string]$Path,
    [Object]$Body,
    [string]$ApiUrl,
    [bool]$Insecure
)

function digest {
    Param([byte[]]$secret, [string]$message)

    $hmacsha = New-Object System.Security.Cryptography.HMACSHA256
    $hmacsha.key = $secret
    $mac = $hmacsha.ComputeHash([Text.Encoding]::ASCII.GetBytes($message))
    return $mac
}

function hexDigest {
    Param([byte[]]$secret, [string]$message)
    
    $bytes = digest -secret $secret -message $message
    return (($bytes|ForEach-Object ToString x2) -join '')
}

function getSigningKey {
    Param([pscredential]$Credential, [System.Collections.IDictionary]$Headers)

    $encoder = New-Object System.Text.UTF8Encoding
    $bytes = $encoder.Getbytes("SDX2" + $Credential.GetNetworkCredential().Password)
    $sign = digest -secret $bytes -message $Headers["X-SDX-Date"]
    $sign = digest -secret $sign -message $Headers["host"]
    $sign = digest -secret $sign -message ("sdx2_request" + $Headers["X-SDX-AuthToken"])
    return $sign
}
function SignRequest {
    Param([pscredential]$Credential, [string]$Method, [System.Uri]$Url, [System.Collections.IDictionary]$Headers, [System.Object]$Body)

    $canonical = $Method.ToUpper() + "`n" + $uri.AbsolutePath + "`n"
    $sortedHeaders = $headers.GetEnumerator() | Sort-Object -Property Name
    $signedHeaders = @()
    $canonicalHeaders = @()
    foreach ($kvp in $sortedHeaders.GetEnumerator()) {
        $signedHeaders += $kvp.Key.ToLower()
        $canonicalHeaders += ($kvp.Key.ToLower() + ":" + $kvp.Value)
    }

    $signingKey = getSigningKey -Credential $Credential -Headers $Headers
    $headers["X-Sdx-Signedheaders"] = $signedHeaders -join ";"
    $canonical += ($canonicalHeaders -join "`n") + "`n"
    $canonical += ($signedHeaders -join ";") + "`n"
    if ($Body) {
        $canonical += (hexDigest -secret $signingKey -message ($Body | ConvertTo-Json -Compress -Depth 100))
    }

    $signature = digest -secret $signingKey -message $canonical
    $Headers["X-Sdx-Signature"] = [Convert]::ToBase64String($signature)    
}

if (!$ApiUrl) {
    $ApiUrl = "https://neon-api.midfinsystems.com"
}

$uri = [System.Uri]($ApiUrl + "/api/v1/" + $Path)
$headers = @{}
$headers["Host"] = $uri.Host
$headers["X-Sdx-Date"] = Get-Date ([datetime]::UtcNow) -UFormat "%Y-%m-%d %H:%M:%S UTC"
$headers["X-Sdx-Authtoken"] = $Credential.UserName
SignRequest -Credential $Credential -Method $Method -Uri $uri -Headers $headers -Body $Body
$headers["Accept"] = "json"
Invoke-RestMethod -Method $Method -Uri $uri.AbsoluteUri -Headers $headers -Body ($Body | ConvertTo-Json -Compress -Depth 100)
    