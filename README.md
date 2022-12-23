# gate-status
 PowerShell script to use Microsoft Azure cogni

Get-GateStatus requires an Azure custom vision resource to be setup and trained prior to use. See https://learn.microsoft.com/en-us/azure/cognitive-services/custom-vision-service/get-started-build-detector for more information.

    You will create a new project with these intial settings:
    - Project type: Classification
    - Domains: Can be General [A1], General, and others

    You will want to have at least 100 training images (preferrably 100 for each status)

    Once you have the project setup you can test by running this script from the command line with the correct parameters. If you schedule this script you may want to hardcode the values for your project to make it more simple.

