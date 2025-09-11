# Teardown State Machine using terraform-aws-modules/step-functions/aws
module "teardown_instance_step_function" {
  source  = "terraform-aws-modules/step-functions/aws"
  version = "~> 4.2"

  name = "${var.prefix}-${var.region}-teardown-spot-instance"

  # Create IAM role for Step Function
  create_role = true
  role_name   = "${var.prefix}-${var.region}-teardown-instance-role"

  # IAM role policies
  attach_policy_statements = true
  policy_statements = [
    {
      effect    = "Allow"
      actions   = ["autoscaling:SetDesiredCapacity"]
      resources = [module.autoscaling.autoscaling_group_arn]
    },
    {
      effect    = "Allow"
      actions   = ["ecs:ListTasks", "ecs:StopTask"]
      resources = ["*"]
    }
  ]

  logging_configuration = {
    include_execution_data = true
    level                  = "ALL"
  }

  definition = jsonencode({
    StartAt = "ListTasks"
    States = {
      ListTasks = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:ecs:listTasks"
        Parameters = {
          Cluster = module.ecs.cluster_arn
        }
        Next = "CheckTasksExist"
      }
      CheckTasksExist = {
        Type = "Choice"
        Choices = [
          {
            Variable      = "$.taskArns"
            IsPresent     = true
            StringMatches = "*"
            Next          = "StopTasks"
          }
        ],
        Default = "SetASGCapacityToZero"
      }
      StopTasks = {
        Type      = "Map"
        ItemsPath = "$.taskArns"
        Parameters = {
          "taskArn.$" : "$$.Map.Item.Value"
          "cluster" : module.ecs.cluster_arn
        }
        Iterator = {
          StartAt = "StopTask"
          States = {
            StopTask = {
              Type     = "Task"
              Resource = "arn:aws:states:::aws-sdk:ecs:stopTask"
              Parameters = {
                "Cluster.$" : "$.cluster"
                "Task.$" : "$.taskArn"
                "Reason" : "Spot instance provisioning disabled"
              }
              End = true
            }
          }
        }
        Next = "SetASGCapacityToZero"
      }
      SetASGCapacityToZero = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:autoscaling:setDesiredCapacity"
        Parameters = {
          AutoScalingGroupName = module.autoscaling.autoscaling_group_name
          DesiredCapacity      = 0
        }
        End = true
      }
    }
  })
}

# EventBridge for teardown events using terraform-aws-modules/eventbridge/aws
module "teardown_eventbridge" {
  source  = "terraform-aws-modules/eventbridge/aws"
  version = "~> 3.14"

  create_bus        = false
  create_role       = true
  role_name         = "${var.prefix}-${var.region}-teardown-events-role"
  attach_sfn_policy = true
  sfn_target_arns   = [module.teardown_instance_step_function.state_machine_arn]

  rules = {
    "${var.prefix}-${var.region}-spot-instance-teardown" = {
      description = "Handle spot instance teardown requests"
      event_pattern = jsonencode({
        source      = ["${var.prefix}.spotorchestrator"]
        detail-type = ["SpotInstanceTeardown"]
      })
    }
  }

  targets = {
    "${var.prefix}-${var.region}-spot-instance-teardown" = [
      {
        name            = "TeardownSpotInstance"
        arn             = module.teardown_instance_step_function.state_machine_arn
        attach_role_arn = true
        role_name       = "${var.prefix}-${var.region}-teardown-events-role"
      }
    ]
  }
}
