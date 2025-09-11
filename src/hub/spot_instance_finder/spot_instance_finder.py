import json
import os
from datetime import datetime, timedelta, timezone

import boto3
from botocore.exceptions import ClientError

ec2 = boto3.client("ec2")

def get_region_recommendation(regions: list, instance_type: str) -> str:
    """
   Get the optimal AWS region based on EC2 spot placement scores.

   Args:
       regions (list): List of AWS region names to evaluate

   Returns:
       str: Region name with highest spot placement score and lowest spot price,
            or None if no valid scores found
   """

    try:
        res = ec2.get_spot_placement_scores(
            InstanceTypes=[instance_type],
            RegionNames=regions,
            TargetCapacityUnitType="units",
            TargetCapacity=1,
        )
    except ClientError:
        return None
    scores = res["SpotPlacementScores"]
    print(f"SpotPlacementScores: {scores}")

    if len(scores) == 0:
        return None

    max_score = max(map(lambda x: x["Score"], scores))
    suitable_regions = list(
        map(lambda x: x["Region"], filter(lambda x: x["Score"] == max_score, scores))
    )
    print(f"suitable regions: {suitable_regions}")

    if len(suitable_regions) == 1:
        return suitable_regions[0]

    # there are multi suitable regions, check the cheap-est one by checking spot pricing history
    region_prices = []
    for region in suitable_regions:
        try:
            res = boto3.client("ec2", region_name=region).describe_spot_price_history(
                InstanceTypes=[instance_type],
                StartTime=(datetime.now(timezone.utc) - timedelta(hours=1)).isoformat(),
                EndTime=datetime.now(timezone.utc).isoformat(),
            )
        except ClientError:
            continue
        prices = list(
            map(lambda x: [x["SpotPrice"], x["Timestamp"]], res["SpotPriceHistory"])
        )
        print(f"({region}) prices: {prices}")
        # find the latest price
        price = max(prices, key=lambda x: x[1])[0]
        region_prices.append({"region": region, "price": price})
    print(f"region prices: {region_prices}")

    return min(region_prices, key=lambda x: x["price"])["region"]


def handler(event, _):
    """
    Lambda handler to find optimal region for spot instance.

    Args:
        event: Lambda event containing exclude_regions list
        _: Lambda context (unused)

    Returns:
        str: Recommended region name
    """

    # Get regions from environment variable, default to all AWS regions if not set
    instance_type = os.environ.get("INSTANCE_TYPE", "p5en.48xlarge")
    all_regions = os.environ.get("ALL_REGIONS", "").strip()
    if all_regions:
        all_regions = [r.strip() for r in all_regions.split(",") if r.strip()]
        print(f"Using configured regions: {all_regions}")
    else:
        # If ALL_REGIONS not set, get all available regions from AWS
        try:
            all_regions = [region['RegionName'] for region in ec2.describe_regions()['Regions']]
            print(f"Using all available AWS regions: {all_regions}")
        except ClientError:
            print("Failed to get regions, using default set")
            all_regions = ["us-east-1", "us-west-2", "eu-west-1"]

    # Get excluded regions from event, default to empty list if not provided
    exclude = event.get("exclude_regions", [])
    if not isinstance(exclude, list):
        print(f"Warning: exclude_regions must be a list, got {type(exclude)}. Using empty list.")
        exclude = []

    print(f"Excluding regions: {exclude}")

    # Filter available regions
    regions = [r for r in all_regions if r not in exclude]
    if not regions:
        print("Error: No regions available after filtering!")
        return None

    print(f"Searching for spot instances in regions: {regions}")
    try:
        result = get_region_recommendation(regions, instance_type)
        print(f"Recommended region: {result}")
        return {"region": result}
    except Exception:
        print("Error finding optimal region")
        return {"region": None}


if __name__ == "__main__":
    handler({"exclude_regions": []}, None)
