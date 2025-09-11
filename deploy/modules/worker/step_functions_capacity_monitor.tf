# Capacity Monitor State Machine using terraform-aws-modules/step-functions/aws
module "capacity_monitor_step_function" {
  source  = "terraform-aws-modules/step-functions/aws"
  version = "~> 4.2"

  name = "${var.prefix}-${var.region}-spot-capacity-monitor"

  create_role = true
  role_name   = "${var.prefix}-${var.region}-capacity-monitor-role"

  attach_policy_statements = true
  policy_statements = [
    {
      effect    = "Allow"
      actions   = ["autoscaling:DescribeAutoScalingGroups"]
      resources = [module.autoscaling.autoscaling_group_arn]
    },
    {
      effect    = "Allow"
      actions   = ["ec2:DescribeInstances"]
      resources = ["*"]
    },
    {
      effect    = "Allow"
      actions   = ["events:PutEvents"]
      resources = ["arn:aws:events:*:${data.aws_caller_identity.current.account_id}:event-bus/default"]
    },
    {
      effect    = "Allow"
      actions   = ["lambda:InvokeFunction"]
      resources = [module.instance_details_lambda.lambda_function_arn]
    },
    {
      effect    = "Allow"
      actions   = ["iam:PassRole"]
      resources = ["*"]
    },
    {
      effect    = "Allow"
      actions   = ["states:StartExecution"]
      resources = ["arn:aws:states:*:${data.aws_caller_identity.current.account_id}:stateMachine:${var.prefix}-*"]
    }
  ]

  logging_configuration = {
    include_execution_data = true
    level                  = "ALL"
  }

  definition = jsonencode({
    QueryLanguage = "JSONata"
    StartAt       = "SetNotify"
    States = {
      SetNotify = {
        Type = "Choice"
        Choices = [{
          Condition = "{% $exists($states.input.notify) and $states.input.notify = false %}"
          Assign = {
            "notify" = "{% false %}"
          }
          Next = "InitializeRetryCount"
        }]
        Default = "InitializeRetryCount"
        Assign = {
          "notify" = "{% true %}"
        }
      }
      InitializeRetryCount = {
        Type = "Pass"
        Assign = {
          retry_count = 1
        }
        Next = "GetInstanceDetails"
      }
      GetInstanceDetails = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Arguments = {
          FunctionName = module.instance_details_lambda.lambda_function_arn
          Payload      = {}
        }
        Next   = "CheckInstancesExist"
        Output = "{% $states.result %}"
      }
      CheckInstancesExist = {
        Type = "Choice"
        Choices = [{
          Condition = "{% $states.input.Payload.launched = true %}"
          Next      = "Success"
          }, {
          Condition = "{% $states.input.Payload.launched = false %}"
          Next      = "WaitForInstance"
        }]
        Default = "WaitForInstance"
      }
      WaitForInstance = {
        Type    = "Wait"
        Seconds = 60
        Next    = "EvaluateRetryCount"
      }
      EvaluateRetryCount = {
        Type = "Choice"
        Choices = [{
          Condition = "{% $retry_count >= ${var.max_retry_count} %}"
          Next      = "ScaleDown"
        }]
        Default = "IncrementRetryCount"
      }
      IncrementRetryCount = {
        Type = "Pass"
        Assign = {
          "retry_count" = "{% $retry_count + 1 %}"
        }
        Next = "GetInstanceDetails"
      }
      ScaleDown = {
        Type     = "Task"
        Resource = "arn:aws:states:::states:startExecution.sync"
        Arguments = {
          StateMachineArn = module.teardown_instance_step_function.state_machine_arn
          Input = {
            reason = "Capacity exhausted after maximum retries"
          }
        }
        Next = "CheckNotify"
      }
      CheckNotify = {
        Type = "Choice"
        Choices = [
          {
            Condition = "{% $notify = true %}"
            Next      = "NotifyHubRegion"
          }
        ]
        Default = "Success"
      }
      NotifyHubRegion = {
        Type     = "Task"
        Resource = "arn:aws:states:::events:putEvents"
        Arguments = {
          Entries = [{
            EventBusName = "default"
            Source       = "${var.prefix}.spotworker"
            DetailType   = "SpotCapacityExhausted"
            Detail = {
              "operation" : "launch_failure"
              "region" : "{% $states.context.Execution.Input.region %}"
            }
          }]
        }
        End = true
      }
      Success = {
        Type = "Succeed"
      }
    }
  })
}


# Local variable to check if current region is hub region
locals {
  is_hub_region = data.aws_region.current.name == var.hub_region
}

# EventBridge for cross-region communication using terraform-aws-modules/eventbridge/aws
module "cross_region_eventbridge" {
  source  = "terraform-aws-modules/eventbridge/aws"
  version = "~> 3.14"

  count = local.is_hub_region ? 0 : 1

  create_bus = false
  # Create IAM role for EventBridge cross-region
  create_role              = true
  role_name                = "${var.prefix}-${var.region}-eventbridge-cross-region-worker-role"
  attach_policy_statements = true
  policy_statements = {
    events = {
      effect  = "Allow"
      actions = ["events:PutEvents"]
      resources = [
        "arn:aws:events:${var.hub_region}:${data.aws_caller_identity.current.account_id}:event-bus/default"
      ]
    }
  }

  rules = {
    "${var.prefix}-${var.region}-to-hub" = {
      description = "Forward updates to hub region"
      event_pattern = jsonencode({
        source = ["${var.prefix}.spotworker"]
      })
    }
  }

  targets = {
    "${var.prefix}-${var.region}-to-hub" = [
      {
        name            = "send-to-hub"
        arn             = "arn:aws:events:${var.hub_region}:${data.aws_caller_identity.current.account_id}:event-bus/default"
        role_name       = "${var.prefix}-${var.region}-eventbridge-cross-region-worker-role"
        attach_role_arn = true
      }
    ]
  }
}
