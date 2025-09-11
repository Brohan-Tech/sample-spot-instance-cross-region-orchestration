# ECS Cluster using terraform-aws-modules/ecs/aws
module "ecs" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "~> 5.12"

  cluster_name = coalesce(var.cluster_name, "${var.prefix}-${var.region}-gpu-cluster")

  # Capacity provider - autoscaling groups
  default_capacity_provider_use_fargate = false
  autoscaling_capacity_providers = {
    gpu = {
      auto_scaling_group_arn         = module.autoscaling.autoscaling_group_arn
      managed_termination_protection = "DISABLED"

      # Disable managed scaling as scaling is handled by step functions
      managed_scaling = {
        status = "DISABLED"
      }

      default_capacity_provider_strategy = {
        weight = 1
        base   = 1
      }
    }
  }

  tags = {
    Environment = "gpu-workload"
  }
}

# Security Group for ECS instances using terraform-aws-modules/security-group/aws
module "autoscaling_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.3"

  name        = "${var.prefix}-${var.region}-ecs-asg-sg"
  description = "Security group for ECS instances"
  vpc_id      = data.aws_vpc.default.id

  egress_rules = ["all-all"]
}

# IAM Role for ECS instances using terraform-aws-modules/iam/aws

module "ecs_instance_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role"
  version = "~> 5.52"

  create_role = true
  role_name   = "${var.prefix}-${var.region}-ecs-instance-role"

  create_instance_profile = true

  custom_role_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
  ]

  trusted_role_services = [
    "ec2.amazonaws.com"
  ]

  role_requires_mfa = false
}

# Auto Scaling Group using terraform-aws-modules/autoscaling/aws
module "autoscaling" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 8.1"

  name = "${var.prefix}-${var.region}-ecs-gpu-asg"

  vpc_zone_identifier  = data.aws_subnets.default.ids
  min_size             = 0
  max_size             = var.asg_max_size
  desired_capacity     = 0
  health_check_type    = "EC2"
  force_delete         = true
  termination_policies = ["OldestInstance"]
  instance_market_options = {
    market_type = "spot"
  }

  # Launch template
  launch_template_name   = "${var.prefix}-${var.region}-ecs-gpu-lt"
  update_default_version = true

  image_id      = data.aws_ami.ecs_gpu.id
  instance_type = var.instance_type

  block_device_mappings = [
    {
      # Root volume
      device_name = "/dev/xvda"
      no_device   = 0
      ebs = {
        delete_on_termination = true
        volume_size           = 300
        volume_type           = "gp3"
      }
    }
  ]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo "ECS_CLUSTER=${coalesce(var.cluster_name, "${var.prefix}-${var.region}-gpu-cluster")}" >> /etc/ecs/ecs.config

    # Install EFS utilities
    yum install -y amazon-efs-utils

    # Create mount point
    mkdir -p /mnt

    # Mount EFS
    mount -t efs ${module.efs.id}:/ /mnt

    # Add to fstab for persistence
    echo "${module.efs.id}:/ /mnt efs defaults,_netdev 0 0" >> /etc/fstab

    chmod -R 777 /mnt
    EOF
  )

  ebs_optimized     = true
  enable_monitoring = true

  iam_instance_profile_name = module.ecs_instance_role.iam_instance_profile_name
  security_groups           = [module.autoscaling_sg.security_group_id]

  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
  }

  instance_refresh = {
    strategy = "Rolling"
    preferences = {
      min_healthy_percentage = 50
    }
  }

  tag_specifications = [{
    resource_type = "instance"
    tags = {
      AmazonECSManaged = "true"
    }
  }]
}

# Latest ECS-optimized AMI with GPU support
data "aws_ami" "ecs_gpu" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-ecs-gpu-*-x86_64-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Create CloudWatch Log Group for ECS tasks
resource "aws_cloudwatch_log_group" "ecs_logs" {
  name              = "/ecs/${var.prefix}"
  retention_in_days = 30

  tags = {
    Name        = "${var.prefix}-${var.region}-ecs-logs"
    Environment = "gpu-workload"
  }
}

# ECS Task Execution Role
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.prefix}-${var.region}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${var.prefix}-${var.region}-ecs-task-execution-role"
    Environment = "gpu-workload"
  }
}

# Attach CloudWatch Logs permissions to the task execution role
resource "aws_iam_role_policy" "ecs_task_execution_cloudwatch_logs" {
  name = "${var.prefix}-${var.region}-ecs-cloudwatch-logs-policy"
  role = aws_iam_role.ecs_task_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "${aws_cloudwatch_log_group.ecs_logs.arn}:*"
      }
    ]
  })
}

# Attach the AWS managed ECS Task Execution Role policy
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS Task Definition
resource "aws_ecs_task_definition" "main" {
  family                   = "${var.prefix}-${var.region}-${var.prefix}-task"
  network_mode             = "host"
  ipc_mode                 = "host"
  requires_compatibilities = ["EC2"]
  memory                   = "10240" # 10 GB in MB
  cpu                      = "4096"  # 4 vCPU in units
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "${var.prefix}"
      image     = var.container_image
      essential = true

      environment = [
        {
          name  = "HF_TOKEN"
          value = ""
        },
        {
          name  = "MODEL_ID"
          value = "deepseek-ai/DeepSeek-R1-Distill-Qwen-7B"
        },
        {
          name  = "GLOO_SOCKET_IFNAME"
          value = "enp39s0"
        },
        {
          name  = "NCCL_SOCKET_IFNAME"
          value = "enp39s0"
        },
        {
          name  = "EXTRA_CMD_ARG"
          value = ""
        }
      ]

      #mountPoints = [
      #  {
      #    sourceVolume  = "huggingface-cache"
      #    containerPath = "/home/model-server/.cache/huggingface"
      #    readOnly      = false
      #  }
      #]

      linuxParameters = {
        sharedMemorySize = 65536
      }

      resourceRequirements = [
        {
          type  = "GPU"
          value = "1"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/${var.prefix}"
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = var.prefix
        }
      }
    }
  ])

  volume {
    name      = "huggingface-cache"
    host_path = "/root/.cache/huggingface"
  }
}
