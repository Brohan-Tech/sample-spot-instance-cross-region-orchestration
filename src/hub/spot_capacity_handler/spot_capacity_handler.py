import json
import logging
import os

import boto3

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
sfn_client = boto3.client('stepfunctions')

def lambda_handler(event, context):
    """
    Lambda function to handle spot capacity events from worker regions.

    This function processes events with source "*.spotworker" and detail-type
    "SpotCapacityFulfilled" or "SpotCapacityNotFulfilled". Based on the detail-type,
    it sends a success or failure message to the Step Functions state machine using
    the provided task token.

    Args:
        event (dict): The event data from EventBridge
        context (object): Lambda context object

    Returns:
        dict: Response with status and message
    """
    logger.info(f"Received event: {json.dumps(event)}")

    try:
        # Extract event details
        source = event.get('source', '')
        detail_type = event.get('detail-type', '')
        detail = event.get('detail', {})

        # Validate event
        if not source.endswith('.spotworker'):
            return {
                'statusCode': 400,
                'body': json.dumps({
                    'message': f"Invalid source: {source}. Expected *.spotworker"
                })
            }

        if detail_type not in ['SpotCapacityFulfilled', 'SpotCapacityNotFulfilled']:
            return {
                'statusCode': 400,
                'body': json.dumps({
                    'message': f"Invalid detail-type: {detail_type}. Expected SpotCapacityFulfilled or SpotCapacityNotFulfilled"
                })
            }

        # Extract task token
        task_token = detail.get('TaskToken')
        if not task_token:
            return {
                'statusCode': 400,
                'body': json.dumps({
                    'message': "Missing TaskToken in event detail"
                })
            }

        # Process based on detail-type
        if detail_type == 'SpotCapacityFulfilled':
            # Send success to Step Functions
            logger.info(f"Sending success for task token: {task_token[:8]}...{task_token[-4:]}")
            try:
                sfn_client.send_task_success(
                    taskToken=task_token,
                    output=json.dumps({
                        'status': 'success',
                        'region': detail.get('region', 'unknown'),
                        'operation': detail.get('operation', 'unknown')
                    })
                )
            except Exception as e:
                logger.error(f"Failed to send task success: {str(e)}")
                raise
            message = "Successfully sent task success"
        else:  # SpotCapacityNotFulfilled
            # Send failure to Step Functions
            logger.info(f"Sending failure for task token: {task_token[:8]}...{task_token[-4:]}")
            try:
                sfn_client.send_task_failure(
                    taskToken=task_token,
                    error='SpotCapacityNotFulfilled',
                    cause=json.dumps({
                        'region': detail.get('region', 'unknown'),
                        'operation': detail.get('operation', 'unknown')
                    })
                )
            except Exception as e:
                logger.error(f"Failed to send task failure: {str(e)}")
                raise
            message = "Successfully sent task failure"

        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': message
            })
        }

    except Exception as e:
        logger.error(f"Error processing event: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({
                'message': f"Error processing event: {str(e)}"
            })
        }
