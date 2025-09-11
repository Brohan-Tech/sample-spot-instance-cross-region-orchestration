
# Local variable to exclude hub region from worker regions
locals {
  cross_region_targets = toset([for region in var.worker_regions : region if region != data.aws_region.current.name])
}

# EventBridge for hub region using terraform-aws-modules/eventbridge/aws
module "hub_eventbridge" {
  source  = "terraform-aws-modules/eventbridge/aws"
  version = "~> 3.14"

  create_bus = false
  # Create IAM role for EventBridge
  create_role = true

  attach_policy_statements = true
  policy_statements = {
    step_functions = {
      effect    = "Allow"
      actions   = ["states:StartExecution"]
      resources = [module.spot_orchestrator.state_machine_arn]
    },
    lambda_invoke = {
      effect    = "Allow"
      actions   = ["lambda:InvokeFunction"]
      resources = [module.spot_capacity_handler_lambda.lambda_function_arn]
    }
  }

  rules = {
    "${var.prefix}-hub-worker-region-failure" = {
      description = "Handle worker region capacity exhaustion"
      event_pattern = jsonencode({
        source      = ["${var.prefix}.spotworker"]
        detail-type = ["SpotCapacityExhausted"]
      })
    },
    "${var.prefix}-hub-spot-capacity-events" = {
      description = "Handle spot capacity fulfillment events"
      event_pattern = jsonencode({
        source      = ["${var.prefix}.spotworker"]
        detail-type = ["SpotCapacityFulfilled", "SpotCapacityNotFulfilled"]
      })
    }
  }

  targets = {
    "${var.prefix}-hub-worker-region-failure" = [
      {
        name            = "RestartRegionChoice"
        arn             = module.spot_orchestrator.state_machine_arn
        role_name       = "${var.prefix}-hub-eventbridge-role"
        attach_role_arn = true

        # Input transformer
        input_transformer = {
          input_paths = {
            "region" = "$.detail.region"
          }
          input_template = "{\"exclude_regions\": [\"<region>\"]}"
        }
      }
    ],
    "${var.prefix}-hub-spot-capacity-events" = [
      {
        name            = "SpotCapacityHandler"
        arn             = module.spot_capacity_handler_lambda.lambda_function_arn
        role_name       = "${var.prefix}-hub-eventbridge-role"
        attach_role_arn = true
      }
    ]
  }
}

# EventBridge for cross-region communication using terraform-aws-modules/eventbridge/aws
module "cross_region_eventbridge" {
  source  = "terraform-aws-modules/eventbridge/aws"
  version = "~> 3.14"

  for_each = local.cross_region_targets

  create_bus = false
  # Create IAM role for EventBridge cross-region
  create_role = true
  role_name   = "${var.prefix}-hub-eventbridge-${each.value}-role"

  attach_policy_statements = true
  policy_statements = {
    events = {
      effect  = "Allow"
      actions = ["events:PutEvents"]
      resources = [
        "arn:aws:events:${each.value}:${data.aws_caller_identity.current.account_id}:event-bus/default"
      ]
    }
  }

  rules = {
    "${var.prefix}-hub-forward-to-${each.value}" = {
      description = "Forward spot instance requests to ${each.value}"
      event_pattern = jsonencode({
        source      = ["${var.prefix}.spotorchestrator"]
        detail-type = ["SpotInstanceRequest"]
        detail = {
          "region" : [each.value]
        }
      })
    }
  }

  targets = {
    "${var.prefix}-hub-forward-to-${each.value}" = [
      {
        name            = "SendTo-${title(each.value)}"
        arn             = "arn:aws:events:${each.value}:${data.aws_caller_identity.current.account_id}:event-bus/default"
        role_name       = "${var.prefix}-hub-eventbridge-${each.value}-role"
        attach_role_arn = true

      }
    ]
  }
}