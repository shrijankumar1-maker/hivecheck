#!/bin/bash
# Creates, once, everything on AWS that stays the same between releases, for both
# environments, plus production's deploy role as the last release process left it.
#
#     bash infra/bootstrap.sh
#
# A pipeline updates services that already exist. It does not create them. So
# this script makes:
#
#   hivecheck                         the ECR repository, with immutable tags
#   token.actions.githubusercontent.com   GitHub's OIDC identity provider, if the account has none
#   hivecheck-execution-role          the role ECS uses to pull the image and write logs
#   /ecs/hivecheck                    the log group both environments write to
#   hivecheck-task-sg                 a security group in the default VPC, port 8000 open
#   hivecheck-staging                 the staging cluster, task definition family and service
#   hivecheck-production              the production cluster, task definition family and service
#                                     (each service is named hivecheck-api and runs one task
#                                     with a public IP)
#   github-deploy-hivecheck-production   production's deploy role. It trusts a job on the
#                                     main branch of your repository, and may push to ECR and
#                                     update the production service, with the inline policy
#                                     deploy-production
#
# The first task definition revision in each environment runs a plain nginx image
# as a placeholder. It does not answer on port 8000. The pipeline replaces it.
#
# It reads your repository from /home/user/github_creds.json, so fill that in first.
# Safe to run again: anything that already exists is left as it is, and the
# production role's trust and policy are only written when the role is new.
set -u
REGION=us-west-2
export AWS_REGION=$REGION AWS_DEFAULT_REGION=$REGION AWS_PAGER=""
A="aws --region $REGION"
PLACEHOLDER=public.ecr.aws/docker/library/nginx:stable-alpine
CREDS=/home/user/github_creds.json
PROD_ROLE=github-deploy-hivecheck-production
SCRATCH="$(cd "$(dirname "$0")/.." && pwd)/scratch"

step() { printf '\n== %s\n' "$*"; }
die() { printf '\nSTOPPED: %s\n' "$*"; exit 1; }

step "Your repository"
TOKEN=$(jq -r '.access_token // empty' "$CREDS" 2>/dev/null)
REPO="$(jq -r '.username // empty' "$CREDS" 2>/dev/null)/$(jq -r '.repository_name // empty' "$CREDS" 2>/dev/null)"
case "$TOKEN$REPO" in *"<"* | "/") die "fill in $CREDS first (Task 1)";; esac
PREFIX=$(curl -s -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/$REPO/actions/oidc/customization/sub" \
    | jq -r '.sub_claim_prefix // empty')
[ -n "$PREFIX" ] || die "GitHub did not return the OIDC subject for $REPO. Check username, repository_name and access_token in $CREDS, and that the repository exists."
echo "$REPO, OIDC subject prefix $PREFIX"

step "Account"
ACCOUNT=$($A sts get-caller-identity --query Account --output text) || die "the AWS CLI is not signed in"
echo "account $ACCOUNT, region $REGION"

step "ECR repository hivecheck"
if $A ecr describe-repositories --repository-names hivecheck >/dev/null 2>&1; then
    echo "already exists"
else
    $A ecr create-repository --repository-name hivecheck --image-tag-mutability IMMUTABLE \
        --query 'repository.imageTagMutability' --output text || die "could not create the ECR repository"
fi

step "GitHub's OIDC identity provider"
OIDC_ARN="arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"
if $A iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
    echo "already exists"
else
    $A iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
        --client-id-list sts.amazonaws.com >/dev/null || die "could not create the OIDC provider"
    echo "created"
fi

step "Task execution role hivecheck-execution-role"
if ! $A iam get-role --role-name hivecheck-execution-role >/dev/null 2>&1; then
    $A iam create-role --role-name hivecheck-execution-role \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
        >/dev/null || die "could not create the role hivecheck-execution-role"
    echo "created"
else
    echo "already exists"
fi
$A iam attach-role-policy --role-name hivecheck-execution-role \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy \
    || die "could not attach AmazonECSTaskExecutionRolePolicy"
EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/hivecheck-execution-role"

step "Log group /ecs/hivecheck"
$A logs create-log-group --log-group-name /ecs/hivecheck 2>/dev/null && echo "created" || echo "already exists"
$A logs put-retention-policy --log-group-name /ecs/hivecheck --retention-in-days 1 2>/dev/null

step "Security group hivecheck-task-sg in the default VPC"
VPC=$($A ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
[ -n "$VPC" ] && [ "$VPC" != None ] || die "this account has no default VPC in $REGION"
SUBNETS=$($A ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" Name=default-for-az,Values=true \
    --query 'Subnets[].SubnetId' --output text | tr '\t' ',')
[ -n "$SUBNETS" ] || die "the default VPC has no default subnets"
SG=$($A ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC" Name=group-name,Values=hivecheck-task-sg \
    --query 'SecurityGroups[0].GroupId' --output text)
if [ -z "$SG" ] || [ "$SG" = None ]; then
    SG=$($A ec2 create-security-group --vpc-id "$VPC" --group-name hivecheck-task-sg \
        --description "hivecheck tasks, port 8000 from anywhere" --query GroupId --output text) \
        || die "could not create the security group"
fi
$A ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 8000 --cidr 0.0.0.0/0 >/dev/null 2>&1
echo "$SG in $VPC"

step "ECS's service-linked role"
# A fresh account has no AWSServiceRoleForECS until ECS makes it, in the background,
# on first use. Asking for it up front avoids most of the wait; the retries below
# cover the rest.
$A iam create-service-linked-role --aws-service-name ecs.amazonaws.com >/dev/null 2>&1 \
    && echo "created" || echo "already exists, or ECS will create it"

for ENV in staging production; do
    NAME="hivecheck-$ENV"
    step "Cluster $NAME"
    # On an account that has never used ECS, the first call can fail while AWS
    # creates ECS's own service-linked role. Waiting and trying again fixes it.
    for try in 1 2 3 4; do
        STATUS=$($A ecs create-cluster --cluster-name "$NAME" --query cluster.status --output text 2>/tmp/hivecheck-cluster.err)
        [ "$STATUS" = ACTIVE ] && break
        echo "not ready yet ($(tail -n 1 /tmp/hivecheck-cluster.err | cut -c1-120)), trying again in 20 s"
        sleep 20
    done
    [ "$STATUS" = ACTIVE ] || die "the cluster $NAME could not be created"
    echo "ACTIVE"

    step "Task definition $NAME (placeholder)"
    if [ "$($A ecs list-task-definitions --family-prefix "$NAME" --query 'length(taskDefinitionArns)' --output text)" = 0 ]; then
        $A ecs register-task-definition --family "$NAME" \
            --requires-compatibilities FARGATE --network-mode awsvpc --cpu 256 --memory 512 \
            --runtime-platform cpuArchitecture=X86_64,operatingSystemFamily=LINUX \
            --execution-role-arn "$EXEC_ROLE_ARN" \
            --container-definitions "[{\"name\":\"hivecheck\",\"image\":\"$PLACEHOLDER\",\"essential\":true,
                \"portMappings\":[{\"containerPort\":8000,\"protocol\":\"tcp\"}],
                \"logConfiguration\":{\"logDriver\":\"awslogs\",\"options\":{\"awslogs-group\":\"/ecs/hivecheck\",
                \"awslogs-region\":\"$REGION\",\"awslogs-stream-prefix\":\"$ENV\"}}}]" \
            --query 'taskDefinition.[family, revision]' --output text || die "could not register the task definition $NAME"
    else
        echo "already registered"
    fi

    step "Service hivecheck-api in $NAME"
    SVC=$($A ecs describe-services --cluster "$NAME" --services hivecheck-api \
        --query 'services[0].status' --output text 2>/dev/null)
    if [ "$SVC" != ACTIVE ]; then
        # Until ECS's service-linked role is ready, CreateService fails with "Unable to
        # assume the service linked role". It clears within a minute or two.
        CREATED=""
        for try in 1 2 3 4 5 6 7 8; do
            CREATED=$($A ecs create-service --cluster "$NAME" --service-name hivecheck-api \
                --task-definition "$NAME" --desired-count 1 --launch-type FARGATE \
                --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=ENABLED}" \
                --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true}" \
                --query 'service.status' --output text 2>/tmp/hivecheck-service.err) && break
            CREATED=""
            grep -q "service linked role" /tmp/hivecheck-service.err || break
            echo "ECS's service-linked role is not ready yet, trying again in 20 s"
            sleep 20
        done
        [ -n "$CREATED" ] || die "could not create the service in $NAME: $(tail -n 1 /tmp/hivecheck-service.err)"
        echo "$CREATED"
    else
        echo "already exists"
    fi
done

step "Production's deploy role $PROD_ROLE"
if $A iam get-role --role-name "$PROD_ROLE" >/dev/null 2>&1; then
    echo "already exists, left as it is"
else
    mkdir -p "$SCRATCH"
    cat > "$SCRATCH/bootstrap-trust.json" <<EOF
{"Version": "2012-10-17", "Statement": [{"Effect": "Allow",
  "Principal": {"Federated": "$OIDC_ARN"}, "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {"StringEquals": {"token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
                                 "token.actions.githubusercontent.com:sub": "${PREFIX}:ref:refs/heads/main"}}}]}
EOF
    cat > "$SCRATCH/bootstrap-policy.json" <<EOF
{"Version": "2012-10-17", "Statement": [
  {"Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*"},
  {"Effect": "Allow", "Action": ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload",
     "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage"],
   "Resource": "arn:aws:ecr:${REGION}:${ACCOUNT}:repository/hivecheck"},
  {"Effect": "Allow", "Action": ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"], "Resource": "*"},
  {"Effect": "Allow", "Action": ["ecs:UpdateService", "ecs:DescribeServices"],
   "Resource": "arn:aws:ecs:${REGION}:${ACCOUNT}:service/hivecheck-production/hivecheck-api"},
  {"Effect": "Allow", "Action": "iam:PassRole", "Resource": "$EXEC_ROLE_ARN",
   "Condition": {"StringEquals": {"iam:PassedToService": "ecs-tasks.amazonaws.com"}}}]}
EOF
    $A iam create-role --role-name "$PROD_ROLE" --assume-role-policy-document "file://$SCRATCH/bootstrap-trust.json" \
        >/dev/null || die "could not create the role $PROD_ROLE"
    $A iam put-role-policy --role-name "$PROD_ROLE" --policy-name deploy-production \
        --policy-document "file://$SCRATCH/bootstrap-policy.json" || die "could not give $PROD_ROLE its policy"
    echo "created, trusting ${PREFIX}:ref:refs/heads/main"
fi

step "Waiting for both services to be stable (about two minutes)"
for ENV in staging production; do
    $A ecs wait services-stable --cluster "hivecheck-$ENV" --services hivecheck-api \
        && echo "$ENV stable" || echo "$ENV not stable yet; check the service's Events tab in the console"
done

step "Done"
echo "Staging:    cluster hivecheck-staging, service hivecheck-api, family hivecheck-staging"
echo "Production: cluster hivecheck-production, service hivecheck-api, family hivecheck-production"
echo "Container hivecheck in both, region $REGION, execution role:"
echo "  $EXEC_ROLE_ARN"
echo "Production's deploy role. Store this ARN as the repository secret AWS_ROLE_ARN:"
echo "  arn:aws:iam::${ACCOUNT}:role/$PROD_ROLE"
