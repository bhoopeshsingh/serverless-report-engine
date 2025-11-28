terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Variables
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "function_name" {
  description = "Lambda function name"
  type        = string
  default     = "serverless-report-engine"
}

variable "lambda_memory" {
  description = "Lambda memory in MB"
  type        = number
  default     = 3008
}

variable "lambda_timeout" {
  description = "Lambda timeout in seconds"
  type        = number
  default     = 300
}

# S3 Bucket for Reports
resource "aws_s3_bucket" "reports" {
  bucket = "${var.function_name}-reports-${data.aws_caller_identity.current.account_id}"
  
  tags = {
    Name        = "Report Engine Storage"
    Environment = "production"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "reports_lifecycle" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "expire-old-reports"
    status = "Enabled"

    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket = aws_s3_bucket.reports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "${var.function_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Lambda execution policy
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# S3 access policy
resource "aws_iam_role_policy" "s3_access" {
  name = "${var.function_name}-s3-access"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.reports.arn}/*"
      }
    ]
  })
}

# Lambda Function
resource "aws_lambda_function" "report_engine" {
  filename      = "../../target/serverless-report-engine-1.0.0-SNAPSHOT.jar"
  function_name = var.function_name
  role          = aws_iam_role.lambda_role.arn
  handler       = "com.reportengine.lambda.LambdaHandler::handleRequest"
  
  source_code_hash = filebase64sha256("../../target/serverless-report-engine-1.0.0-SNAPSHOT.jar")
  
  runtime = "java17"
  memory_size = var.lambda_memory
  timeout     = var.lambda_timeout
  
  environment {
    variables = {
      REPORT_BUCKET = aws_s3_bucket.reports.bucket
    }
  }
  
  tags = {
    Name        = "Report Engine Lambda"
    Environment = "production"
  }
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = 14
}

# API Gateway
resource "aws_apigatewayv2_api" "report_api" {
  name          = "${var.function_name}-api"
  protocol_type = "HTTP"
  
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["Content-Type"]
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.report_api.id
  name        = "$default"
  auto_deploy = true
  
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_logs.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }
}

resource "aws_cloudwatch_log_group" "api_logs" {
  name              = "/aws/apigateway/${var.function_name}"
  retention_in_days = 7
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id             = aws_apigatewayv2_api.report_api.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.report_engine.invoke_arn
  integration_method = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "generate" {
  api_id    = aws_apigatewayv2_api.report_api.id
  route_key = "POST /generate"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.report_engine.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.report_api.execution_arn}/*/*"
}

# Get current AWS account ID
data "aws_caller_identity" "current" {}

# Outputs
output "api_endpoint" {
  description = "API Gateway endpoint URL"
  value       = aws_apigatewayv2_api.report_api.api_endpoint
}

output "s3_bucket" {
  description = "S3 bucket for reports"
  value       = aws_s3_bucket.reports.bucket
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.report_engine.function_name
}
