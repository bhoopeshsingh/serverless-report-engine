# Deployment Guide

## Prerequisites

Before deploying the Serverless Report Engine, ensure you have:

- **AWS Account** with appropriate permissions
- **AWS CLI** installed and configured (`aws configure`)
- **Java 17** or higher
- **Maven 3.8+**
- **Terraform 1.0+** (optional, for IaC deployment)

## Build the Application

```bash
# Navigate to project root
cd /path/to/serverless-report-engine

# Clean and package
mvn clean package

# Verify the JAR was created
ls -lh target/serverless-report-engine-1.0.0-SNAPSHOT.jar
```

The build process creates a fat JAR with all dependencies using Maven Shade plugin.

## Option 1: Terraform Deployment (Recommended)

### Step 1: Configure Variables

Edit `infrastructure/aws/main.tf` or create a `terraform.tfvars`:

```hcl
aws_region      = "us-east-1"
function_name   = "report-engine"
lambda_memory   = 3008
lambda_timeout  = 300
```

### Step 2: Deploy

```bash
cd infrastructure/aws

# Initialize Terraform
terraform init

# Preview changes
terraform plan

# Apply configuration
terraform apply
```

### Step 3: Get Outputs

```bash
# Get API endpoint
terraform output api_endpoint

# Get S3 bucket name
terraform output s3_bucket

# Example output:
# api_endpoint = "https://abc123.execute-api.us-east-1.amazonaws.com"
# s3_bucket = "report-engine-reports-123456789"
```

## Option 2: Manual AWS Deployment

### Step 1: Create IAM Role

```bash
# Create trust policy
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create role
aws iam create-role \
  --role-name ReportEngineLambdaRole \
  --assume-role-policy-document file://trust-policy.json

# Attach basic execution policy
aws iam attach-role-policy \
  --role-name ReportEngineLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
```

### Step 2: Create S3 Bucket

```bash
# Create bucket (use a unique name)
aws s3 mb s3://my-report-engine-bucket

# Enable lifecycle rule to delete old reports
cat > lifecycle.json <<EOF
{
  "Rules": [
    {
      "Id": "DeleteOldReports",
      "Status": "Enabled",
      "Expiration": {
        "Days": 30
      }
    }
  ]
}
EOF

aws s3api put-bucket-lifecycle-configuration \
  --bucket my-report-engine-bucket \
  --lifecycle-configuration file://lifecycle.json
```

### Step 3: Grant S3 Permissions

```bash
cat > s3-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3:::my-report-engine-bucket/*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name ReportEngineLambdaRole \
  --policy-name S3Access \
  --policy-document file://s3-policy.json
```

### Step 4: Create Lambda Function

```bash
# Get role ARN
ROLE_ARN=$(aws iam get-role --role-name ReportEngineLambdaRole --query 'Role.Arn' --output text)

# Create function
aws lambda create-function \
  --function-name serverless-report-engine \
  --runtime java17 \
  --role $ROLE_ARN \
  --handler com.reportengine.lambda.LambdaHandler::handleRequest \
  --zip-file fileb://target/serverless-report-engine-1.0.0-SNAPSHOT.jar \
  --timeout 300 \
  --memory-size 3008 \
  --environment Variables="{REPORT_BUCKET=my-report-engine-bucket}"
```

### Step 5: Create API Gateway

```bash
# Create HTTP API
API_ID=$(aws apigatewayv2 create-api \
  --name report-engine-api \
  --protocol-type HTTP \
  --query 'ApiId' \
  --output text)

# Create integration
INTEGRATION_ID=$(aws apigatewayv2 create-integration \
  --api-id $API_ID \
  --integration-type AWS_PROXY \
  --integration-uri arn:aws:lambda:us-east-1:ACCOUNT_ID:function:serverless-report-engine \
  --payload-format-version 2.0 \
  --query 'IntegrationId' \
  --output text)

# Create route
aws apigatewayv2 create-route \
  --api-id $API_ID \
  --route-key 'POST /generate' \
  --target integrations/$INTEGRATION_ID

# Create stage
aws apigatewayv2 create-stage \
  --api-id $API_ID \
  --stage-name '$default' \
  --auto-deploy

# Grant API Gateway permission to invoke Lambda
aws lambda add-permission \
  --function-name serverless-report-engine \
  --statement-id apigateway-invoke \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:us-east-1:ACCOUNT_ID:$API_ID/*/*"

# Get API endpoint
echo "https://$API_ID.execute-api.us-east-1.amazonaws.com/generate"
```

## Testing the Deployment

### Test with Sample Request

```bash
# Test Excel generation
curl -X POST https://YOUR_API_ENDPOINT/generate \
  -H "Content-Type: application/json" \
  -d @examples/sql-to-excel.json

# Test CSV generation
curl -X POST https://YOUR_API_ENDPOINT/generate \
  -H "Content-Type: application/json" \
  -d @examples/sql-to-csv.json
```

### Test with AWS CLI

```bash
# Create test payload
cat > test-payload.json <<EOF
{
  "body": "{\"reportType\":\"CSV\",\"dataSource\":{\"type\":\"SQL\",\"query\":\"SELECT 1 as id, 'test' as name\",\"connectionString\":\"jdbc:postgresql://localhost:5432/db\",\"username\":\"user\",\"password\":\"pass\"},\"config\":{\"chunkSize\":100}}"
}
EOF

# Invoke Lambda directly
aws lambda invoke \
  --function-name serverless-report-engine \
  --payload file://test-payload.json \
  response.json

# View response
cat response.json | jq .
```

## Monitoring

### CloudWatch Logs

```bash
# View recent logs
aws logs tail /aws/lambda/serverless-report-engine --follow

# View specific log group
aws logs describe-log-streams \
  --log-group-name /aws/lambda/serverless-report-engine \
  --order-by LastEventTime \
  --descending
```

### Metrics

Monitor these CloudWatch metrics:

- **Invocations**: Number of requests
- **Duration**: Processing time
- **Errors**: Failed requests
- **Throttles**: Rate-limited requests
- **Memory Usage**: Peak memory consumption

## Updating the Function

### Update Code

```bash
# Rebuild
mvn clean package

# Update function
aws lambda update-function-code \
  --function-name serverless-report-engine \
  --zip-file fileb://target/serverless-report-engine-1.0.0-SNAPSHOT.jar
```

### Update Configuration

```bash
# Increase memory
aws lambda update-function-configuration \
  --function-name serverless-report-engine \
  --memory-size 4096

# Update timeout
aws lambda update-function-configuration \
  --function-name serverless-report-engine \
  --timeout 600
```

## Troubleshooting

### Lambda Timeout

If reports are timing out:
- Increase timeout: `--timeout 600`
- Increase memory: `--memory-size 5120`
- Reduce chunk size in request

### Out of Memory

If Lambda runs out of memory:
- Increase memory allocation
- Reduce `excelMemoryWindow` config
- Use CSV/Parquet instead of Excel for large datasets

### Connection Errors

For database connection issues:
- Ensure Lambda has VPC access to database
- Check security groups allow traffic
- Verify connection string format
- Test credentials

### S3 Upload Failures

If S3 uploads fail:
- Verify IAM role has S3 permissions
- Check bucket exists and is accessible
- Ensure bucket name is correct

## Security Considerations

1. **Secrets Management**: Use AWS Secrets Manager for database credentials
2. **VPC**: Deploy Lambda in VPC for database access
3. **Encryption**: Enable S3 bucket encryption
4. **IAM**: Use least-privilege permissions
5. **API Gateway**: Add authentication (API keys, Cognito, etc.)

## Cost Optimization

- Use lifecycle policies to delete old reports
- Right-size Lambda memory (test with different sizes)
- Monitor invocations and optimize cold starts
- Consider reserved concurrency for predictable workloads

## Next Steps

- Set up CI/CD pipeline
- Add monitoring dashboards
- Implement authentication
- Configure custom domain
- Set up alerts for errors
