import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    """
    Retrieve region, public/private IP address for instances in ASG
    """
    region = boto3.Session().region_name
    asg_name = os.environ.get('ASG_NAME')
    prefix = os.environ.get('PREFIX')
    
    if not asg_name or not prefix:
        return {'error': 'Required environment variables not set'}

    # get desired and current inservice count from asg
    asg = boto3.client('autoscaling', region_name=region)
    ec2 = boto3.client('ec2', region_name=region)

    try:
        asg_response = asg.describe_auto_scaling_groups(
            AutoScalingGroupNames=[asg_name]
        )
        if not asg_response['AutoScalingGroups']:
            return {'error': 'Auto Scaling Group not found'}
            
        asg_group = asg_response['AutoScalingGroups'][0]
        desired_count = asg_group['DesiredCapacity']
        current_count = len([i for i in asg_group['Instances'] if i['LifecycleState'] == 'InService'])
        ssm = boto3.client('ssm', region_name=os.environ['HUB_REGION'])
    except Exception as e:
        logger.error(f"Error accessing ASG: {str(e)}")
        return {'error': 'Failed to access Auto Scaling Group'}

    instances_info = []
    if desired_count == current_count and current_count > 0:
        # put region, public IP (if available) and private IP to ssm parameter
        instances = asg_group['Instances']
        try:
            # Batch describe instances for better performance
            instance_ids = [i['InstanceId'] for i in instances if i['LifecycleState'] == 'InService']
            if instance_ids:
                instances_response = ec2.describe_instances(InstanceIds=instance_ids)
                for reservation in instances_response['Reservations']:
                    for instance in reservation['Instances']:
                        instances_info.append({
                            'instance_id': instance['InstanceId'],
                            'public_ip': instance.get('PublicIpAddress', 'None'),
                            'private_ip': instance['PrivateIpAddress']
                        })
            # put instances_info into ssm
            param_output = {
                "region": region,
                "instances": instances_info
            }
            ssm.put_parameter(
                Name=f'/{prefix}/instances-info',
                Value=json.dumps(param_output),
                Type='String',
                Overwrite=True
            )
            return {"launched": True}
        except Exception as e:
            logger.error(f"Error getting instance details: {str(e)}")
            return {'error': 'Failed to get instance details'}
    else:
        logger.error(f"Desired and current instance count do not match, expect {desired_count} but get {current_count}")
        return {"launched": False}