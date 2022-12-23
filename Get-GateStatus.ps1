<#
    .SYNOPSIS 
    This script uses Azure custom vision that has been trained to return a status and then activate a webhook.
    .DESCRIPTION
    Get-GateStatus requires an Azure custom vision resource to be setup and trained prior to use. See https://learn.microsoft.com/en-us/azure/cognitive-services/custom-vision-service/get-started-build-detector 
    for more information.

    You will create a new project the initial settings:
    - Project type: Classification
    - Domains: Can be General [A1], General, and others

    You will want to have at least 100 training images (preferrably 100 for each status)

    Once you have the project setup you can test by running this script from the command line with the correct parameters. If you schedule this script you may want to hardcode the values for your project to make it more simple.


    .PARAMETER Threshold
    Percentage threshold needed to be sure. Must be in decimal form.
    .PARAMETER ImageNamePrefix
    Prefix of image to save, it will automatically add a date at the end of the file name.
    .PARAMETER FilePath
    Path to save the images and status file
    .PARAMETER FFMpegPath
    Path where FFMpeg.exe is located
    .PARAMETER CameraURI 
    URI to retrieve the picture from the camera
    .PARAMETER PredictionKey
    Prediction key from Azure Custom Vision service
    .PARAMETER AIUri
    URI to your custom vision project endpoint
    .PARAMETER WebhookUri
    URI to webhook for after status is determined.
    .PARAMETER StatusFile
    The name of the file to create to keep the status of the gate to know if there is a change.
    .PARAMETER CollectOnly
    Specify if you only want to collect camera images. This is usefull for collecting training images
    .PARAMETER NoCleanUp
    Specify if you want to keep all generated files
    .PARAMETER IgnorePreviousStatus
    Specify if you want to ignore the last status. This will make sure to automatically trigger the change condition.
    
#>

[CmdletBinding()]
param (
    [Parameter()]
    # Percentage threshold needed to be sure. Must be in decimal form.
    $Threshold = .70,
    # Name of image to save
    $ImageNamePrefix = "Gate",
    # Path to save the images and status file
    $FilePath = $env:Temp,
    # Path to FFMpeg if not in environment PATH
    $FFMpegPath = "C:\Program Files\FFMPEG\bin",
    # URI for the camera
    $CameraURI,
    # Prediction Key needed for the AI service
    $PredictionKey,
    # URI for the Azure AI Web service
    $AIUri = "",
    # URI for Webhook kicked off after.
    $WebhookUri,
    # File name to write the gate status
    $StatusFile = "GateStatus.txt",
    # Use this to collect images and not submit to AI for processing
    [switch]$CollectOnly,
    # Don't cleanup files
    [switch]$NoCleanUp,
    # Use this switch to ignore previous status
    [switch]$IgnorePreviousStatus
)

function Get-GateSchedule {
    <#
    TODO: This will provide the logic for the gate schedule. So if it is open during a certain time, you may not care to notify. However if it is left open after hours, you may want to 
    take other actions. 
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [TypeName]
        $Time
    )

}

function Send-TeamsCard {
    <#
    .SYNOPSIS
    Sends a Microsoft Teams adaptive card
    
    #>
    [CmdletBinding()]
    param (
        # Message you want to send in the card
        [Parameter()]
        [string]
        $Message,
        # Image you want to attach to the adaptive card
        [Parameter()]
        [string]
        $Image,
        # Webhook URI to post adaptive card.
        [Parameter()]
        [string]
        $Uri,
        # Container style for the adaptive card to highlight the status.
        [Parameter()]
        [ValidateSet("default", "emphasis", "good", "attention", "warning", "accent")]
        [string]
        $ContainerStyle = "default"
    )

    $webhookHeaders = @{"Content-Type" = "application/json" }
    $webhookBody = [Ordered]@{
        "type"        = "message"
        "attachments" = @(
            @{
                "contentType" = 'application/vnd.microsoft.card.adaptive'
                "content"     = [Ordered]@{
                    '$schema' = "<http://adaptivecards.io/schemas/adaptive-card.json>"
                    "type"    = "AdaptiveCard"
                    "version" = "1.2"
                    "body"    = @(
                        @{
                            "type"  = "Container"
                            "style" = $ContainerStyle
                            "items" = @(
                                @{
                                    "type"     = "TextBlock"
                                    "text"     = "Gate Status"
                                    "size"     = "Large"
                                    "weight"   = "Bolder"
                                    "isSubtle" = $true
                                    "wrap"     = $true
                                }
                                @{
                                    "type" = "TextBlock"
                                    "text" = "$Message"
                                    "wrap" = $true
                                }
                                @{
                                    "type"    = "Image"
                                    "url"     = "$Image"
                                    "altText" = "Gate picture"
                                       
                                }
                            )
                        }
                    )
                }
            }
        )
    } | ConvertTo-Json -Depth 20

    Write-Output "`n  JSON body:`n"
    $webhookBody

    $whResponse = Invoke-RestMethod -Method Post -Uri $Uri -Body $webhookBody -Verbose -Headers $webhookHeaders -TimeoutSec 45
    Write-Output "`n Response:"    
    $whResponse | Format-Table -AutoSize -ErrorAction SilentlyContinue

}

$ImageName = "$ImageNamePrefix-$(Get-Date -f yyyyMMdd-HHmmss).png"
$FilePath = $FilePath.TrimEnd("\")
$FullImagePath = "$FilePath\$($ImageName)"
$FullThumbImagePath = "$FilePath\Thm$($ImageName)"
$FullThumbImagePath = $FullThumbImagePath.Replace(".png", ".jpg")
$HighProbTag = ""
$cardStyle = "default"

# Test if ffmpeg is available and if not add the default path to the PATH environment
if ($null -eq (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue)) {
    $env:Path += ";$FFMPEGPath"
}

# Use FFMPEG to get the image from the camera
# In this example I am cropping the image to only the needed area, this helps the AI not get distracted.
# & "ffmpeg.exe" -skip_frame nokey -i $CameraURI -frames:v 2 -update 1 -f image2 -qscale:v 2 -vf "crop=640:350:80:5" -y $FullImagePath
# You can adjust ffmpeg settings here to get the right quality and area you need.
& "ffmpeg.exe" -skip_frame nokey -i $CameraURI -frames:v 2 -update 1 -f image2 -qscale:v 2 -y $FullImagePath

if ($CollectOnly.IsPresent -eq $false) {
    # Grab a thumbnail version of the image for posting
    & "ffmpeg.exe" -i $FullImagePath -qscale:v 28 -y -update 1 -f image2 $FullThumbImagePath
    $FullStatusPath = "$FilePath\$StatusFile"
    $PreviousStatus = Get-Content $FullStatusPath -ErrorAction SilentlyContinue
    
    # Full image file bytes
    $fileBytes = [System.IO.File]::ReadAllBytes("$FullImagePath")
    # Thumbnail image converted to base64
    $b64ThumbImage = "data:image/jpeg;base64,"
    $b64ThumbImage += [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($FullThumbImagePath))

    $headers = @{
        "Prediction-Key" = $PredictionKey
        "Content-Type"   = "application/json"
    }

    $webhookHeaders = @{"Content-Type" = "application/json" }
    
    # Submit image to Custom Vision service
    $response = Invoke-RestMethod -Method POST -Uri $AIUri -Headers $headers -Body $fileBytes
    
    # What is the most probable gate status?
    $IsHighProb = $response.predictions | Where-Object Probability -gt $threshold
    $HighProbTag = $IsHighProb.tagName

    # Is there a change in status or was the IgnorePreviousStatus switch   
    if (($IsHighProb.tagName -ne $PreviousStatus) -or ($IgnorePreviousStatus.IsPresent)) {

        $CardMessage = ""
        if ($null -eq $IsHighProb) {
            
            $HighProbTag = "its complicated" 
            $cardStyle = "attention"
        }
       
        $IsHighProb.tagName | Out-File "$FilePath\$StatusFile" -Force
        $CardMessage = "The gate is $HighProbTag at $(Get-Date)"
        Write-Output "`n $CardMessage `n "
        #$b64ThumbImage = "data:image/gif;base64,R0lGODlhAQABAAAAACw="
        # Send the message
        Send-TeamsCard -Message $CardMessage -Image $b64ThumbImage -Uri $WebhookUri -ContainerStyle $cardStyle
        Write-Output "`n    Done - $(Get-Date)`n"
    }
    else {
        Write-Output "`n`n   Gate status hasn't changed: $HighProbTag - $(Get-Date)`n"
    }
    # Write this out for debugging   
    $response.predictions | Format-Table @{Label = "Probability"; Expression = { $_.Probability * 100 } }, tagName

    if ($NoCleanUp.IsPresent -eq $false) {
        Write-Output "Cleaning up temp files..."
        Remove-Item $FullImagePath -Force -ErrorAction SilentlyContinue
        Remove-Item $FullThumbImagePath -Force -ErrorAction SilentlyContinue
    }
    else {

        $RenImagePath = $FullImagePath.Replace(".png", "-$($HighProbTag).png")
        Rename-Item $FullImagePath $RenImagePath
        Remove-Item $FullThumbImagePath -Force -ErrorAction SilentlyContinue
    }

}
else {

    Write-Output "`n    Camera image saved to: $FullImagePath $(Get-Date)`n"

}

