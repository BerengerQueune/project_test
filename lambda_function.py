import os
import json
import boto3
from io import BytesIO
from pyspark.sql import SparkSession
from pyspark.sql.types import StructType, StructField, StringType

# Initialize AWS clients
dynamodb = boto3.resource("dynamodb")
s3 = boto3.client("s3")

# Environment variables
TABLE_NAME = os.environ["TABLE_NAME"]
BUCKET_NAME = os.environ["BUCKET_NAME"]

def lambda_handler(event, context):
    table = dynamodb.Table(TABLE_NAME)
    
    # Scan the table (fetch all data)
    response = table.scan()
    data = response.get("Items", [])

    if not data:
        print("No data found in the table.")
        return {"statusCode": 200, "body": "No data to backup"}

    # Start a Spark session (local mode, since Lambda has no Spark cluster)
    spark = SparkSession.builder.appName("DynamoDBToParquet").getOrCreate()

    # Define schema dynamically based on keys in the first row
    schema = StructType([StructField(key, StringType(), True) for key in data[0].keys()])

    # Convert JSON data to a Spark DataFrame
    df = spark.createDataFrame(data, schema=schema)

    # Convert DataFrame to Parquet (write to in-memory buffer)
    parquet_buffer = BytesIO()
    df.write.parquet(parquet_buffer)

    # Upload Parquet file to S3
    s3.put_object(
        Bucket=BUCKET_NAME,
        Key="dynamodb_backup.parquet",
        Body=parquet_buffer.getvalue(),
        ContentType="application/octet-stream"
    )

    return {"statusCode": 200, "body": "Backup saved in Parquet format"}