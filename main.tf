# Get AWS Account ID
data "aws_caller_identity" "current" {}

resource "aws_dynamodb_table" "minimal_table" {
  name         = "MinimalTable"
  billing_mode = "PAY_PER_REQUEST"

  attribute {
    name = "id"
    type = "S"
  }

  hash_key = "id"
}

resource "aws_s3_bucket" "backup_bucket" {
  bucket_prefix = "dynamodb-backup-"
  force_destroy = true
}

# Register the S3 bucket in AWS Lake Formation
resource "aws_lakeformation_resource" "s3_data_lake" {
  arn                     = aws_s3_bucket.backup_bucket.arn
  use_service_linked_role = true
}

# Glue Database for storing metadata
resource "aws_glue_catalog_database" "glue_database" {
  name = "dynamodb_backup_db"
}

# Glue IAM Role for the Crawler
resource "aws_iam_role" "glue_role" {
  name = "AWSGlueServiceRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Attach Glue permissions for reading from S3
resource "aws_iam_policy" "glue_policy" {
  name        = "GlueS3AccessPolicy"
  description = "Allows Glue to read from S3 and register tables in Glue Catalog"
  policy      = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.backup_bucket.arn,
          "${aws_s3_bucket.backup_bucket.arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["glue:*"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "glue_policy_attach" {
  role       = aws_iam_role.glue_role.name
  policy_arn = aws_iam_policy.glue_policy.arn
}

# Glue Crawler to scan S3 and update Glue Catalog
resource "aws_glue_crawler" "glue_crawler" {
  name          = "dynamodb_backup_crawler"
  role          = aws_iam_role.glue_role.arn
  database_name = aws_glue_catalog_database.glue_database.name
  table_prefix  = "dynamodb_backup_"
  
  s3_target {
    path = "s3://${aws_s3_bucket.backup_bucket.id}/"
  }
}

# Glue Trigger to run the Glue Crawler every day at 3 AM
resource "aws_glue_trigger" "daily_glue_crawler_trigger" {
  name     = "daily_glue_crawler_trigger"
  schedule = "cron(0 3 * * ? *)"
  type     = "SCHEDULED"

  actions {
    crawler_name = aws_glue_crawler.glue_crawler.name
  }
}

# IAM Role for Lambda Function
resource "aws_iam_role" "lambda_role" {
  name = "LambdaDynamoDBS3Role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# IAM Policy for Lambda to read DynamoDB & write to S3
resource "aws_iam_policy" "lambda_policy" {
  name        = "LambdaDynamoDBS3Policy"
  description = "Allows Lambda to read from DynamoDB and write to S3"
  policy      = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:Scan"]
        Resource = aws_dynamodb_table.minimal_table.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.backup_bucket.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# Package Lambda function (ZIP file)
data "archive_file" "lambda_package" {
  type        = "zip"
  source_file = "lambda_function.py"
  output_path = "lambda_function.zip"
}

# Create Lambda function to extract DynamoDB data and save to S3
resource "aws_lambda_function" "dynamodb_to_s3_lambda" {
  function_name    = "DynamoDBToS3Lambda"
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.8"
  role             = aws_iam_role.lambda_role.arn
  filename         = data.archive_file.lambda_package.output_path

  environment {
    variables = {
      TABLE_NAME  = aws_dynamodb_table.minimal_table.name
      BUCKET_NAME = aws_s3_bucket.backup_bucket.id
    }
  }
}

# EventBridge rule to trigger the Lambda function daily at 2 AM
resource "aws_cloudwatch_event_rule" "lambda_trigger_rule" {
  name                = "DailyLambdaTrigger"
  schedule_expression = "cron(0 2 * * ? *)"
}

# EventBridge Target to invoke Lambda function
resource "aws_cloudwatch_event_target" "lambda_trigger" {
  rule      = aws_cloudwatch_event_rule.lambda_trigger_rule.name
  target_id = "LambdaDynamoDBToS3Trigger"
  arn       = aws_lambda_function.dynamodb_to_s3_lambda.arn
}

# Allow EventBridge to invoke Lambda function
resource "aws_lambda_permission" "allow_eventbridge_lambda" {
  statement_id  = "AllowEventBridgeInvokeLambda"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dynamodb_to_s3_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_trigger_rule.arn
}