import json
import os

import boto3
from botocore.exceptions import ClientError

# Initialize clients outside handler for reuse
ssm = boto3.client('ssm')

def lambda_handler(event, context):
    prefix = os.environ.get('PREFIX')
    if not prefix:
        return {
            'statusCode': 500,
            'body': json.dumps({'error': 'PREFIX environment variable not set'})
        }

    # Parameter name to fetch - you can modify this or pass it through the event
    parameter_name = f"/{prefix}/instances-info"

    try:
        # Get the parameter value
        # WithDecryption=True will automatically decrypt SecureString parameters
        response = ssm.get_parameter(
            Name=parameter_name,
            WithDecryption=True
        )

        parameter_value = response['Parameter']['Value']

        return {
            'statusCode': 200,
            'body': json.dumps(json.loads(parameter_value)) if parameter_value.startswith('{') else parameter_value
        }

    except ClientError as e:
        error_message = e.response['Error']['Message']
        error_code = e.response['Error']['Code']

        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': error_message,
                'error_code': error_code
            })
        }
    except Exception as e:
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': str(e)
            })
        }
