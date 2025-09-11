# Step Function state machine using terraform-aws-modules/step-functions/aws
module "spot_orchestrator" {
  source  = "terraform-aws-modules/step-functions/aws"
  version = "~> 4.2"

  name = "${var.prefix}-hub-spot-instance-orchestrator"

  # Create IAM role for Step Function
  create_role = true
  role_name   = "${var.prefix}-hub-spot-orchestrator-role"

  # IAM role policies
  service_integrations = {
    lambda = {
      lambda = [module.spot_finder_lambda.lambda_function_arn]
    }
    eventbridge = {
      eventbridge = ["*"]
    }
    stepfunction_Sync = {
      stepfunction_Wildcard = ["*"]
    }
  }

  logging_configuration = {
    include_execution_data = true
    level                  = "ALL"
  }

  attach_policy_statements = true
  policy_statements = [{
    actions   = ["ssm:PutParameter", "ssm:DeleteParameter"]
    resources = ["arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/${var.prefix}/*"]
    }, {
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:DescribeParameters"]
    resources = ["*"]
    }, {
    actions   = ["states:ListExecutions", "states:DescribeExecution", "states:StopExecution"]
    resources = ["arn:aws:states:*:${data.aws_caller_identity.current.account_id}:*"]
  }]

  # Enable JSONata query language
  definition = jsonencode({
    QueryLanguage = "JSONata"
    StartAt       = "GetEnableStatus"
    States = {
      GetEnableStatus = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:ssm:getParameter"
        Arguments = {
          Name = "/${var.prefix}/provisioning-enabled"
        }
        Output = {
          enabled = "{% $states.result.Parameter.Value %}"
        }
        Assign = {
          exclude_regions = "{% $states.input.exclude_regions %}"
        }
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Assign = {
            exclude_regions = "{% [] %}"
          }
          Next = "CheckEnabled"
        }]
        Next = "CheckEnabled"
      }

      CheckEnabled = {
        Type = "Choice"
        Choices = [{
          Condition = "{% enabled = 'false' %}"
          Next      = "Success"
        }]
        Default = "FindOptimalRegion"
      }

      FindOptimalRegion = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Arguments = {
          FunctionName = module.spot_finder_lambda.lambda_function_arn
          Payload = {
            exclude_regions = "{% $exclude_regions %}"
          }
        }
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "WaitAndRetry"
        }]
        Next = "CheckSpotFinderResult"
      }

      CheckSpotFinderResult = {
        Type = "Choice"
        Choices = [{
          Condition = "{% $states.input.Payload.region != null %}"
          Next      = "WriteProvisioningStatus"
          Assign = {
            desired_region = "{% $states.input.Payload.region %}"
          }
        }]
        Default = "WriteNotAvailableStatus"
      }

      WriteProvisioningStatus = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:ssm:putParameter"
        Arguments = {
          Name      = "/${var.prefix}/status"
          Type      = "String"
          Value     = "PROVISIONING"
          Overwrite = true
        }
        Next = "WriteRegion"
      }

      WriteRegion = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:ssm:putParameter"
        Arguments = {
          Name      = "/${var.prefix}/region"
          Type      = "String"
          Value     = "{% $desired_region %}"
          Overwrite = true
        }
        Next = "SendEventToWorker"
      }

      SendEventToWorker = {
        Type     = "Task"
        Resource = "arn:aws:states:::events:putEvents.waitForTaskToken"
        Arguments = {
          Entries = [{
            EventBusName = "default"
            Source       = "${var.prefix}.spotorchestrator"
            DetailType   = "SpotInstanceRequest"
            Detail = {
              action    = "launch"
              region    = "{% $desired_region %}"
              TaskToken = "{% $states.context.Task.Token %}"
            }
          }]
        }
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "AddRegionToExcludeList"
        }]
        Next = "WriteCompleteStatus"
      }

      AddRegionToExcludeList = {
        Type = "Pass"
        Assign = {
          exclude_regions = "{% $append($exclude_regions, $desired_region) %}"
        }
        Next = "FindOptimalRegion"
      }

      WriteCompleteStatus = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:ssm:putParameter"
        Arguments = {
          Name      = "/${var.prefix}/status"
          Type      = "String"
          Value     = "COMPLETED"
          Overwrite = true
        }
        Next = "Success"
      }

      WriteNotAvailableStatus = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:ssm:putParameter"
        Arguments = {
          Name      = "/${var.prefix}/status"
          Type      = "String"
          Value     = "NOTAVAILABLE"
          Overwrite = true
        }
        Next = "ResetAndRetry"
      }

      ResetAndRetry = {
        Type = "Pass"
        Assign = {
          exclude_regions = []
        }
        Next = "WaitAndRetry"
      }

      WaitAndRetry = {
        Type    = "Wait"
        Seconds = var.retry_wait_time
        Next    = "FindOptimalRegion"
      }

      Success = {
        Type = "Pass"
        End  = true
      }
    }
  })
}

# Create a ssm parameter
resource "aws_ssm_parameter" "spot_orchestrator_enabled" {
  name  = "/${var.prefix}/provisioning-enabled"
  type  = "String"
  value = "true"
}