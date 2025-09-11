# Lambda functions using the AWS Lambda module
module "spot_finder_lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.20"

  function_name = "${var.prefix}-hub-spot-instance-finder"
  description   = "Lambda function to find optimal spot instance regions"
  handler       = "spot_instance_finder.handler"
  runtime       = "python3.13"
  memory_size   = 512
  timeout       = 30
  source_path   = "${path.module}/../../../src/hub/spot_instance_finder"

  environment_variables = {
    INSTANCE_TYPE = var.instance_type
    ALL_REGIONS   = join(",", var.worker_regions)
  }

  create_role = true
  role_name   = "${var.prefix}-hub-spot-instance-finder-role"

  attach_policy_statements = true
  policy_statements = {
    ec2_permissions = {
      effect = "Allow",
      actions = [
        "ec2:DescribeSpotPriceHistory",
        "ec2:DescribeAvailabilityZones",
        "ec2:GetSpotPlacementScores",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeRegions"
      ],
      resources = ["*"]
    },
    events_permissions = {
      effect = "Allow",
      actions = [
        "events:PutEvents"
      ],
      resources = ["*"]
    },
    ssm_permissions = {
      effect = "Allow",
      actions = [
        "ssm:GetParameter"
      ],
      resources = ["arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/${var.prefix}/*"]
    },
    states_permissions = {
      effect = "Allow",
      actions = [
        "states:StartExecution"
      ],
      resources = ["arn:aws:states:*:${data.aws_caller_identity.current.account_id}:stateMachine:${var.prefix}-*"]
    }
  }

  publish = true

  tags = {
    Name = "${var.prefix}-hub-spot-instance-finder"
  }
}

module "get_instance_details_lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.20"

  function_name = "${var.prefix}-hub-get-spot-instance-details"
  description   = "Lambda function to get spot instance details"
  handler       = "get_instance_details.lambda_handler"
  runtime       = "python3.13"
  memory_size   = 256
  timeout       = 30

  environment_variables = {
    PREFIX = "${var.prefix}"
  }

  source_path = "${path.module}/../../../src/hub/get_instance_details"

  create_role = true
  role_name   = "${var.prefix}-hub-get-instance-details-role"

  attach_policy_statements = true
  policy_statements = {
    ssm_permissions = {
      effect = "Allow",
      actions = [
        "ssm:GetParameter"
      ],
      resources = ["arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/${var.prefix}/*"]
    }
  }

  publish = true

  allowed_triggers = {
    APIGateway = {
      service    = "apigateway"
      source_arn = "${module.api_gateway.api_execution_arn}/*/*/*"
    }
  }

  tags = {
    Name = "${var.prefix}-hub-get-spot-instance-details"
  }
}

module "toggle_provisioning_lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.20"

  function_name = "${var.prefix}-hub-toggle-spot-provisioning"
  description   = "Lambda function to toggle spot instance provisioning"
  handler       = "toggle_provisioning.lambda_handler"
  runtime       = "python3.13"
  memory_size   = 256
  timeout       = 30

  source_path = "${path.module}/../../../src/hub/toggle_provisioning"

  environment_variables = {
    PREFIX                              = "${var.prefix}"
    SPOT_ORCHESTRATOR_ARN               = module.spot_orchestrator.state_machine_arn
    ALL_REGIONS                         = join(",", var.worker_regions)
    SPOT_PROVISIONING_ENABLED_PARAMETER = "/${var.prefix}/provisioning-enabled"
    EVENTBRIDGE_RULE_NAME               = module.hub_eventbridge.eventbridge_rule_arns["${var.prefix}-hub-worker-region-failure"]
  }

  create_role = true
  role_name   = "${var.prefix}-hub-toggle-spot-provisioning-role"

  attach_policy_statements = true
  policy_statements = {
    states_permissions = {
      effect = "Allow",
      actions = [
        "states:StartExecution",
        "states:ListExecutions",
        "states:StopExecution"
      ],
      resources = ["arn:aws:states:*:${data.aws_caller_identity.current.account_id}:stateMachine:${var.prefix}-*"]
    },
    params_permissions = {
      effect = "Allow",
      actions = [
        "ssm:PutParameter"
      ],
      resources = ["arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/${var.prefix}/*"]
    },
    eb_permissions = {
      effect = "Allow",
      actions = [
        "events:EnableRule",
        "events:DisableRule",
        "events:PutRule"
      ],
      resources = ["*"]
    },
  }

  publish = true

  allowed_triggers = {
    APIGateway = {
      service    = "apigateway"
      source_arn = "${module.api_gateway.api_execution_arn}/*/*/*"
    }
  }

  tags = {
    Name = "${var.prefix}-hub-toggle-spot-provisioning"
  }
}

module "spot_capacity_handler_lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.20"

  function_name = "${var.prefix}-hub-spot-capacity-handler"
  description   = "Lambda function to handle spot capacity events"
  handler       = "spot_capacity_handler.lambda_handler"
  runtime       = "python3.13"
  memory_size   = 256
  timeout       = 30

  source_path = "${path.module}/../../../src/hub/spot_capacity_handler"

  create_role = true
  role_name   = "${var.prefix}-hub-spot-capacity-handler-role"

  attach_policy_statements = true
  policy_statements = {
    states_permissions = {
      effect = "Allow",
      actions = [
        "states:SendTaskSuccess",
        "states:SendTaskFailure"
      ],
      resources = ["arn:aws:states:*:${data.aws_caller_identity.current.account_id}:*"]
    }
  }

  publish = true

  tags = {
    Name = "${var.prefix}-hub-spot-capacity-handler"
  }
}

# API Gateway using AWS API Gateway v2 module
module "api_gateway" {
  source  = "terraform-aws-modules/apigateway-v2/aws"
  version = "~> 5.2"

  name          = "${var.prefix}-hub-spot-management-api"
  description   = "Spot Instance Management API"
  protocol_type = "HTTP"

  create_domain_name    = false
  create_domain_records = false
  create_certificate    = false

  cors_configuration = {
    allow_headers = ["content-type", "x-amz-date", "authorization", "x-api-key", "x-amz-security-token", "x-amz-user-agent"]
    allow_methods = ["*"]
    allow_origins = ["*"]
  }

  # Routes and integrations
  routes = {
    "GET /spot-instances" = {
      integration = {
        uri                    = module.get_instance_details_lambda.lambda_function_arn
        payload_format_version = "2.0"
        timeout_milliseconds   = 12000
        integration_type       = "AWS_PROXY"
      }
    }

    "POST /spot-provisioning" = {
      integration = {
        uri                    = module.toggle_provisioning_lambda.lambda_function_arn
        payload_format_version = "2.0"
        timeout_milliseconds   = 12000
        integration_type       = "AWS_PROXY"
      }
    }
  }

  tags = {
    Name = "${var.prefix}-hub-spot-management-api"
  }
}
