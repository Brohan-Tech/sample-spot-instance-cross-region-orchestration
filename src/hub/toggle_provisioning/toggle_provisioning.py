import json
import logging
import os

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize clients outside handler for reuse
sfn = boto3.client('stepfunctions')
ssm = boto3.client('ssm')
eb = boto3.client('events')

def lambda_handler(event, context):
    """
    Toggle spot instance provisioning by starting the orchestrator with enabled/disabled state
    """
    prefix = os.environ.get('PREFIX')
    if not prefix:
        return {
            'statusCode': 500,
            'body': json.dumps({'error': 'PREFIX environment variable not set'})
        }
    
    try:
        # Get action from body
        body = json.loads(event.get('body', '{}'))
        action = body.get('action')

        if not action or action not in ['enable', 'disable']:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'Valid action (enable/disable) is required in request body'})
            }

        eb_rule_name = os.environ['EVENTBRIDGE_RULE_NAME'].split("/")[-1]

        if action == 'enable':
            ssm.put_parameter(Name=os.environ['SPOT_PROVISIONING_ENABLED_PARAMETER'], Value='true', Type='String', Overwrite=True)
            # Enable EventBridge rule to receive spot interruption notifications
            eb.enable_rule(Name=eb_rule_name)
            sfn.start_execution(
                stateMachineArn=os.environ['SPOT_ORCHESTRATOR_ARN'],
                input=json.dumps({
                    "exclude_regions": []
                })
            )
        elif action == 'disable':
            ssm.put_parameter(Name=os.environ['SPOT_PROVISIONING_ENABLED_PARAMETER'], Value='false', Type='String', Overwrite=True)
            # Disable eventbridge rule
            eb.disable_rule(Name=eb_rule_name)

            # find all execution of sfn and exit
            executions = sfn.list_executions(
                stateMachineArn=os.environ['SPOT_ORCHESTRATOR_ARN'],
                statusFilter='RUNNING'
            )
            for execution in executions['executions']:
                sfn.stop_execution(executionArn=execution['executionArn'])

            # Send teardown signal to all regions
            teardown = body.get('teardown')
            if teardown:
                all_regions = os.environ['ALL_REGIONS'].split(',')
                for region in all_regions:
                    eb.put_events(Entries=[
                        {
                            "Source": f"{prefix}.spotorchestrator",
                            "DetailType": "SpotInstanceTeardown",
                            "Detail": json.dumps({
                                "region": region,
                                "action": "teardown"
                            }),
                            "EventBusName": "default"
                        }
                    ])

        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': f'Spot provisioning {action}d successfully'
            })
        }

    except ClientError as e:
        logger.error(f"AWS service error: {e.response['Error']['Code']}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': 'AWS service error occurred'})
        }
    except Exception as e:
        logger.error(f"Unexpected error: {type(e).__name__}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': 'Internal server error'})
        }
