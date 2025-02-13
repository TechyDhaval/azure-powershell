﻿# ----------------------------------------------------------------------------------
#
# Copyright Microsoft Corporation
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ----------------------------------------------------------------------------------


<#
.SYNOPSIS
Tests basic CRUD operations on Batch jobs
#>
function Test-JobCRUD
{
    $context = New-Object Microsoft.Azure.Commands.Batch.Test.ScenarioTests.ScenarioTestContext

    $jobId1 = "job1"
    $jobId2 = "job2"

    try
    {
        $poolInfo1 = New-Object Microsoft.Azure.Commands.Batch.Models.PSPoolInformation
        $poolInfo1.PoolId = "testPool"
        $envSettings = @{
            "ThisIsAString" = "Hello world";
            # Make sure CommonEnvironmentSettings allows null values
            "ThisIsNull" = $null
        }
        New-AzBatchJob -Id $jobId1 -PoolInformation $poolInfo1 -CommonEnvironmentSettings $envSettings -BatchContext $context

        $poolInfo2 = New-Object Microsoft.Azure.Commands.Batch.Models.PSPoolInformation
        $poolInfo2.PoolId = "testPool2"
        New-AzBatchJob -Id $jobId2 -PoolInformation $poolInfo2 -Priority 3 -BatchContext $context

        # List the jobs to ensure they were created
        $jobs = Get-AzBatchJob -Filter "id eq '$jobId1' or id eq '$jobId2'" -BatchContext $context
        $job1 = $jobs | Where-Object { $_.Id -eq $jobId1 }
        $job2 = $jobs | Where-Object { $_.Id -eq $jobId2 }
        Assert-NotNull $job1
        Assert-NotNull $job2

        # Update a job
        $job2.Priority = $newPriority = $job2.Priority + 2
        $job2 | Set-AzBatchJob -BatchContext $context
        $updatedJob = Get-AzBatchJob -Id $jobId2 -BatchContext $context
        Assert-AreEqual $newPriority $updatedJob.Priority
    }
    finally
    {
        # Delete the jobs
        Remove-AzBatchJob -Id $jobId1 -Force -BatchContext $context
        Remove-AzBatchJob -Id $jobId2 -Force -BatchContext $context

        foreach ($job in Get-AzBatchJob -BatchContext $context)
        {
            Assert-True { ($job.Id -ne $jobId1 -and $job.Id -ne $jobId2) -or ($job.State.ToString().ToLower() -eq 'deleting') }
        }
    }
}

<#
.SYNOPSIS
Tests disabling, enabling, and terminating a job
#>
function Test-DisableEnableTerminateJob
{
    param([string]$jobId)

    $context = New-Object Microsoft.Azure.Commands.Batch.Test.ScenarioTests.ScenarioTestContext

    Disable-AzBatchJob $jobId Terminate -BatchContext $context

    # Sleep a bit in Record mode since the job doesn't immediately switch to Disabled.
    Start-TestSleep -Seconds 10

    # Verify the job was Disabled
    $job = Get-AzBatchJob $jobId -BatchContext $context
    Assert-AreEqual 'Disabled' $job.State

    $job | Enable-AzBatchJob -BatchContext $context

    # Verify the job is Active
    $job = Get-AzBatchJob -Filter "id eq '$jobId'" -BatchContext $context
    Assert-AreEqual 'Active' $job.State

    # Terminate the job
    $job | Stop-AzBatchJob -BatchContext $context

    # Verify the job was terminated
    $job = Get-AzBatchJob $jobId -BatchContext $context
    Assert-True { ($job.State.ToString().ToLower() -eq 'terminating') -or ($job.State.ToString().ToLower() -eq 'completed') }
}

<#
.SYNOPSIS
Tests create job with TaskDependencies
#>
function Test-JobWithTaskDependencies
{
    $context = New-Object Microsoft.Azure.Commands.Batch.Test.ScenarioTests.ScenarioTestContext
    $jobId = "testJob4"

    try
    {
        $osFamily = 4
        $targetOS = "*"
        $cmd = "cmd /c dir /s"
        $taskId = "taskId1"

        $paasConfiguration = New-Object Microsoft.Azure.Commands.Batch.Models.PSCloudServiceConfiguration -ArgumentList @($osFamily, $targetOSVersion)

        $poolSpec = New-Object Microsoft.Azure.Commands.Batch.Models.PSPoolSpecification
        $poolSpec.TargetDedicated = $targetDedicated = 3
        $poolSpec.VirtualMachineSize = $vmSize = "standard_d1_v2"
        $poolSpec.CloudServiceConfiguration = $paasConfiguration
        $autoPoolSpec = New-Object Microsoft.Azure.Commands.Batch.Models.PSAutoPoolSpecification
        $autoPoolSpec.PoolSpecification = $poolSpec
        $autoPoolSpec.AutoPoolIdPrefix = $autoPoolIdPrefix = "TestSpecPrefix"
        $autoPoolSpec.KeepAlive =  $FALSE
        $autoPoolSpec.PoolLifeTimeOption = $poolLifeTime = ([Microsoft.Azure.Batch.Common.PoolLifeTimeOption]::Job)
        $poolInformation = New-Object Microsoft.Azure.Commands.Batch.Models.PSPoolInformation
        $poolInformation.AutoPoolSpecification = $autoPoolSpec

        $taskIds = @("2","3")
        $taskIdRange = New-Object Microsoft.Azure.Batch.TaskIdRange(1,10)
        $dependsOn = New-Object Microsoft.Azure.Batch.TaskDependencies -ArgumentList @([string[]]$taskIds, [Microsoft.Azure.Batch.TaskIdRange[]]$taskIdRange)
        New-AzBatchJob -Id $jobId -BatchContext $context -PoolInformation $poolInformation -usesTaskDependencies
        New-AzBatchTask -Id $taskId -CommandLine $cmd -BatchContext $context -DependsOn $dependsOn -JobId $jobId
        $job = Get-AzBatchJob -Id $jobId -BatchContext $context

        Assert-AreEqual $job.UsesTaskDependencies $TRUE
        $task = Get-AzBatchTask -JobId $jobId -Id $taskId -BatchContext $context
        Assert-AreEqual $task.DependsOn.TaskIdRanges.End 10
        Assert-AreEqual $task.DependsOn.TaskIdRanges.Start 1
        Assert-AreEqual $task.DependsOn.TaskIds[0] 2
        Assert-AreEqual $task.DependsOn.TaskIds[1] 3
    }
    finally
    {
        Remove-AzBatchJob -Id $jobId -Force -BatchContext $context
    }
}


<#
.SYNOPSIS
Tests create job completes when any task fails
#>
function IfJobSetsAutoFailure-ItCompletesWhenAnyTaskFails
{
    param([string]$poolId, [string]$jobId, [string]$taskId)

    $context = New-Object Microsoft.Azure.Commands.Batch.Test.ScenarioTests.ScenarioTestContext

    $osFamily = 4
    $targetOS = "*"
    $cmd = "cmd /c exit 3"

    $poolInformation = New-Object Microsoft.Azure.Commands.Batch.Models.PSPoolInformation
    $poolInformation.PoolId = $poolId

    $ExitConditions = New-Object Microsoft.Azure.Commands.Batch.Models.PSExitConditions
    $ExitOptions = New-Object Microsoft.Azure.Commands.Batch.Models.PSExitOptions
    $ExitOptions.JobAction =  [Microsoft.Azure.Batch.Common.JobAction]::Terminate
    $ExitCodeRangeMapping = New-Object Microsoft.Azure.Commands.Batch.Models.PSExitCodeRangeMapping -ArgumentList @(2, 4, $ExitOptions)
    $ExitConditions.ExitCodeRanges = [Microsoft.Azure.Commands.Batch.Models.PSExitCodeRangeMapping[]]$ExitCodeRangeMapping

    New-AzBatchJob -Id $jobId -BatchContext $context -PoolInformation $poolInformation -OnTaskFailure PerformExitOptionsJobAction
    New-AzBatchTask -Id $taskId -CommandLine $cmd -BatchContext $context -JobId $jobId -ExitConditions $ExitConditions
}