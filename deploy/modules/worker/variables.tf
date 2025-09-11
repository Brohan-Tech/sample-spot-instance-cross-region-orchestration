variable "prefix" {
  description = "Prefix to be added to all resource names"
  type        = string
}

variable "region" {
  description = "AWS region for the worker infrastructure"
  type        = string
}

variable "cluster_name" {
  description = "Name of the ECS cluster"
  type        = string
  default     = null
}

variable "instance_type" {
  description = "EC2 instance type for the ASG"
  type        = string
  default     = "p5en.48xlarge"
}

variable "asg_max_size" {
  description = "Maximum size of the Auto Scaling Group"
  type        = number
  default     = 10
}

variable "asg_desired_capacity" {
  description = "Desired capacity of the Auto Scaling Group"
  type        = number
  default     = 1
}

variable "max_retry_count" {
  description = "Maximum number of retries for insufficient capacity"
  type        = number
  default     = 3
}

variable "hub_region" {
  description = "AWS region where the hub infrastructure is deployed"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to deploy resources into"
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "List of subnet IDs to deploy resources into"
  type        = list(string)
  default     = null
}

variable "container_image" {
  description = "Container image URI for ECS tasks"
  type        = string
  default     = "600413481647.dkr.ecr.us-west-2.amazonaws.com/sglang:0.4.3.post2-efa"
}
