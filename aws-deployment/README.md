# Nextcloud AWS Serverless Deployment

Complete AWS deployment solution for Nextcloud using serverless and managed services.

## Architecture

```
Internet → ALB (HTTPS) → ECS Fargate Tasks (2-10 instances)
                              ↓
                         Aurora Serverless v2 (Primary + Replica)
                              ↓
                         ElastiCache Serverless (Redis)
                              ↓
                         S3 Bucket (File Storage)
                         EFS (Config/Apps)
```

### Components

- **ECS Fargate**: Runs Nextcloud PHP containers with auto-scaling (2-10 tasks)
- **Aurora Serverless v2**: PostgreSQL/MySQL database with auto-scaling ACUs (0.5-128)
- **ElastiCache Serverless**: Redis for session storage, file locking, and caching
- **S3**: Primary file storage with versioning and lifecycle policies
- **EFS**: Shared storage for config and custom apps across containers
- **ALB**: Application Load Balancer with SSL termination
- **Secrets Manager**: Secure storage for database and admin passwords
- **CloudWatch**: Logging, metrics, dashboards, and alarms

## Prerequisites

1. **AWS Account** with appropriate permissions
2. **AWS CLI** installed and configured
   ```bash
   aws --version
   aws configure
   ```
3. **Existing VPC** with:
   - At least 2 private subnets (for ECS, RDS, Redis, EFS)
   - At least 2 public subnets (for ALB)
   - NAT Gateway or NAT Instance for private subnet internet access
4. **ACM Certificate** (optional, for custom domain HTTPS)
5. **Python 3** (for cost calculator)
6. **jq** (optional, for better output formatting)

## Quick Start

### 1. Configure Deployment

Copy the example config and fill in your values:

```bash
cd aws-deployment
cp config/deployment-config.env.example config/deployment-config.env
```

Edit `config/deployment-config.env`:

```bash
# Required
VPC_ID="vpc-xxxxx"
PRIVATE_SUBNET_IDS="subnet-xxxxx,subnet-yyyyy"
PUBLIC_SUBNET_IDS="subnet-aaaaa,subnet-bbbbb"
DB_PASSWORD="your-secure-password-min-16-chars"
ADMIN_PASSWORD="your-nextcloud-admin-password"

# Optional
DOMAIN_NAME="cloud.example.com"
CERTIFICATE_ARN="arn:aws:acm:us-east-1:xxxxx:certificate/xxxxx"
```

### 2. Estimate Costs

Preview monthly costs before deploying:

```bash
./scripts/cost-calculator.py small    # 10-50 users (~$80-120/mo)
./scripts/cost-calculator.py medium   # 100-500 users (~$150-250/mo)
./scripts/cost-calculator.py large    # 1000+ users (~$300-500/mo)
./scripts/cost-calculator.py compare  # Compare all scenarios
```

### 3. Deploy

Run the interactive deployment script:

```bash
./scripts/deploy.sh
```

The script will:
- Validate prerequisites
- Check CloudFormation template syntax
- Prompt for any missing parameters
- Show cost estimate
- Deploy the stack
- Wait for completion (15-20 minutes)
- Display access URLs and next steps

### 4. Access Nextcloud

After deployment completes:

1. Wait 5-10 minutes for initial setup
2. Access the URL shown in deployment outputs
3. Login with username: `admin`
4. Retrieve password from AWS Secrets Manager:
   ```bash
   aws secretsmanager get-secret-value \
     --secret-id nextcloud-admin-password \
     --region us-east-1 \
     --query SecretString --output text
   ```

### 5. Configure DNS (if using custom domain)

Point your domain to the ALB DNS name:

```bash
# Get ALB DNS
aws cloudformation describe-stacks \
  --stack-name nextcloud-production \
  --query 'Stacks[0].Outputs[?OutputKey==`LoadBalancerDNS`].OutputValue' \
  --output text

# Create DNS record
cloud.example.com → CNAME → nextcloud-xxx.us-east-1.elb.amazonaws.com
```

## Cost Breakdown

Monthly cost ranges by scenario (US-East-1):

| Component | Small | Medium | Large |
|-----------|-------|--------|-------|
| **Fargate** | $40-60 | $60-90 | $150-220 |
| **Aurora** | $20-30 | $40-80 | $100-200 |
| **Redis** | $5-10 | $10-20 | $30-50 |
| **S3** | $2-5 | $15-30 | $120-180 |
| **ALB** | $20-25 | $25-35 | $40-60 |
| **EFS** | $2-3 | $3-5 | $6-10 |
| **Data Transfer** | $0-5 | $10-20 | $80-100 |
| **Total** | **$90-140** | **$165-280** | **$530-820** |

*Costs vary based on actual usage, region, and workload patterns*

## Monitoring

### CloudWatch Dashboard

Deploy the pre-configured dashboard:

```bash
aws cloudwatch put-dashboard \
  --dashboard-name Nextcloud-Production \
  --dashboard-body file://monitoring/cloudwatch-dashboard.json \
  --region us-east-1
```

View at: CloudWatch Console → Dashboards → Nextcloud-Production

Monitors:
- ECS resource utilization (CPU, memory, task counts)
- Aurora metrics (ACU capacity, CPU, connections)
- Redis performance (cache hits/misses, memory)
- ALB performance (requests, response time, status codes)
- S3 storage metrics
- Application errors (log insights)

### CloudWatch Alarms

Configure alarms for critical issues:

```bash
# Create SNS topic for notifications
aws sns create-topic --name nextcloud-alerts --region us-east-1

# Subscribe to email notifications
aws sns subscribe \
  --topic-arn arn:aws:sns:us-east-1:ACCOUNT_ID:nextcloud-alerts \
  --protocol email \
  --notification-endpoint your-email@example.com

# Deploy alarms (integrate into CloudFormation or use CLI)
# See monitoring/cloudwatch-alarms.yaml for alarm definitions
```

Critical alarms:
- ECS CPU >80% or Memory >85%
- No running tasks or unhealthy targets
- ALB 5xx errors >10 in 5 minutes
- Aurora CPU >80% or connections >90%
- Redis memory >85% or cache hit rate <70%

## Maintenance

### Update Stack

Modify CloudFormation template or parameters, then:

```bash
./scripts/deploy.sh
# Select "update" when prompted
```

### Scale Resources

Update `config/deployment-config.env`:

```bash
MIN_TASKS="4"        # Increase minimum tasks
MAX_TASKS="20"       # Increase maximum tasks
DB_MAX_CAPACITY="32" # Increase Aurora max ACU
```

Then run `./scripts/deploy.sh` to apply changes.

### Backup

Backups are automatically configured:

- **Aurora**: Automated daily snapshots (7-day retention)
- **S3**: Versioning enabled for file recovery
- **EFS**: AWS Backup (if configured separately)

Manual backup:

```bash
# Create Aurora snapshot
aws rds create-db-cluster-snapshot \
  --db-cluster-identifier nextcloud-aurora-cluster \
  --db-cluster-snapshot-identifier nextcloud-manual-backup-$(date +%Y%m%d)

# Enable S3 cross-region replication (disaster recovery)
# Configure via S3 console or CloudFormation
```

### Monitoring Costs

```bash
# View current month costs
aws ce get-cost-and-usage \
  --time-period Start=$(date +%Y-%m-01),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --filter file://<(echo '{"Tags":{"Key":"Project","Values":["Nextcloud"]}}')

# Set budget alert
aws budgets create-budget \
  --account-id ACCOUNT_ID \
  --budget file://budget-config.json
```

## Troubleshooting

### Deployment Fails

Check CloudFormation events:

```bash
aws cloudformation describe-stack-events \
  --stack-name nextcloud-production \
  --region us-east-1 \
  --max-items 20
```

### Nextcloud Not Accessible

1. Check ECS tasks are running:
   ```bash
   aws ecs list-tasks \
     --cluster nextcloud-cluster \
     --service nextcloud-service
   ```

2. Check target health:
   ```bash
   aws elbv2 describe-target-health \
     --target-group-arn <TG_ARN>
   ```

3. Check security groups allow traffic

### Performance Issues

1. Check CloudWatch dashboard for bottlenecks
2. Scale up Aurora ACUs or Fargate tasks
3. Review Redis cache hit rate
4. Check S3 request metrics

### Database Connection Errors

1. Verify Aurora cluster is available
2. Check database password in Secrets Manager
3. Review security group rules
4. Increase max connections if needed

## Cleanup

To delete the entire stack:

```bash
# Delete CloudFormation stack
aws cloudformation delete-stack \
  --stack-name nextcloud-production \
  --region us-east-1

# Wait for deletion
aws cloudformation wait stack-delete-complete \
  --stack-name nextcloud-production \
  --region us-east-1
```

**Note**: S3 bucket with versioning may need manual deletion:

```bash
# Empty bucket first
aws s3 rm s3://your-nextcloud-bucket --recursive
aws s3api delete-bucket --bucket your-nextcloud-bucket
```

## Architecture Decisions

### Why These Services?

- **Fargate vs EC2**: No server management, auto-scaling, pay per task
- **Aurora Serverless vs RDS**: Auto-scaling capacity, pay per ACU-hour
- **ElastiCache Serverless vs Redis EC2**: Fully managed, auto-scaling
- **S3 vs EBS**: Unlimited storage, high durability (99.999999999%)
- **EFS**: Shared file system for multi-container config/apps sync

### Limitations

- **Not 100% serverless**: Fargate tasks run continuously (not event-driven like Lambda)
- **Minimum costs**: Aurora min 0.5 ACU, Fargate min 2 tasks (~$80/month baseline)
- **Cold start**: None (tasks run continuously)
- **Session affinity**: Not required (Redis handles sessions)

### Security

- All secrets in AWS Secrets Manager
- Database in private subnets
- S3 bucket encryption enabled
- VPC security groups restrict access
- IAM roles follow least privilege

## Support

- **Nextcloud Documentation**: https://docs.nextcloud.com
- **AWS Support**: https://console.aws.amazon.com/support
- **Issues**: Report at project repository

## License

This deployment configuration follows Nextcloud's AGPL-3.0 license.
